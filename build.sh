#!/usr/bin/env bash
# build.sh — build vgem.ko + vkms.ko as out-of-tree modules against
# Microsoft's WSL2 kernel source.
#
# Usage:
#   ./build.sh <kernel-tag>          # e.g. linux-msft-wsl-6.18.26.1
#   ./build.sh latest                # auto-resolve newest tag from upstream
#
# Output:
#   dist/vgem-vkms-modules-<tag>.tar.gz
#     containing:
#       vgem.ko
#       vkms.ko
#       manifest.txt   (kernel-tag, vermagic, build metadata)
#
# Designed to run identically locally (./build.sh latest) and in CI
# (.github/workflows/build.yml). The resulting .ko's vermagic is
# determined by the kernel source's UTS_RELEASE + a few config flags
# from CONFIG_MODVERSIONS / CONFIG_SMP / CONFIG_PREEMPT — none of
# which depend on the build host's distro or gcc, so the artifacts
# load on any WSL2 distro running Microsoft's matching stock kernel.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <linux-msft-wsl-X.Y.Z.W | latest>" >&2
    exit 2
fi

TAG="$1"
REPO_URL=https://github.com/microsoft/WSL2-Linux-Kernel.git
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRCDIR="${SRCDIR:-$ROOT/build/WSL2-Linux-Kernel}"
DIST="$ROOT/dist"

# --- resolve the tag ------------------------------------------------
if [ "$TAG" = "latest" ]; then
    TAG=$(git ls-remote --tags --refs "$REPO_URL" 'refs/tags/linux-msft-wsl-*' \
            | awk '{print $2}' \
            | sed 's|refs/tags/||' \
            | sort -V | tail -1)
    if [ -z "$TAG" ]; then
        echo "build.sh: failed to resolve latest tag from $REPO_URL" >&2
        exit 1
    fi
    echo "build.sh: resolved latest tag → $TAG"
fi

case "$TAG" in
    linux-msft-wsl-*) ;;
    *)
        echo "build.sh: tag '$TAG' doesn't look like a Microsoft WSL tag" >&2
        exit 2
        ;;
esac

# --- clone source --------------------------------------------------
mkdir -p "$(dirname "$SRCDIR")"
if [ -d "$SRCDIR/.git" ]; then
    cur=$(git -C "$SRCDIR" describe --tags --exact-match 2>/dev/null) || cur=""
    if [ "$cur" != "$TAG" ]; then
        echo "build.sh: cached source on '$cur', re-cloning at '$TAG'"
        rm -rf "$SRCDIR"
    fi
fi
if [ ! -d "$SRCDIR/.git" ]; then
    echo "build.sh: cloning $REPO_URL ($TAG) → $SRCDIR"
    git clone --depth 1 --branch "$TAG" "$REPO_URL" "$SRCDIR"
fi

# --- apply config overlay ------------------------------------------
# Modules-only build:
#   VGEM=m   — virtual GEM render node (provides /dev/dri/renderD128).
#              Already shipped =m by Microsoft on recent kernels
#              (e.g. 6.6.114.1+); keep here so older kernels still
#              get coverage.
#   VKMS=m   — virtual KMS (provides /dev/dri/card1; needed by some
#              EGL clients that probe the full DRM device set). The
#              actually-missing piece on stock WSL2.
#   DRM_GEM_SHMEM_HELPER=m — VKMS dep, ensure available as module.
#
# We intentionally KEEP CONFIG_DEBUG_INFO_BTF=y. Microsoft ships its
# kernel with CONFIG_DEBUG_INFO_BTF_MODULES=y, which adds two fields
# (`btf_data`, `btf_data_size`) to `struct module`. Disabling BTF
# here would change `struct module`'s layout and every module CRC
# (including module_layout) — so vkms.ko built without BTF gets
# rejected by Microsoft's running kernel with "disagrees about
# version of symbol module_layout" even though vermagic matches.
echo "build.sh: applying config overlay (VGEM=m, VKMS=m, BTF kept on)"
cd "$SRCDIR"
cp arch/x86/configs/config-wsl .config
./scripts/config --module  CONFIG_DRM_VGEM
./scripts/config --module  CONFIG_DRM_VKMS
./scripts/config --module  CONFIG_DRM_GEM_SHMEM_HELPER
make olddefconfig

# --- build modules -------------------------------------------------
# `make modules_prepare` alone doesn't produce Module.symvers — modpost
# then can't resolve `kfree`/`drm_*`/etc and fails with hundreds of
# "undefined" errors. We need a real build that links vmlinux and
# emits Module.symvers. `make` (the default target) does the lot:
# vmlinux + bzImage + all configured modules. The .ko's we want land
# in their respective driver dirs as a side effect.
#
# Cost: ~5–10 min on a GitHub-hosted runner. CI runs once per kernel
# tag so this is amortized; users hit the prebuilt path in 5 seconds.
JOBS=${JOBS:-$(nproc)}

# LOCALVERSION="" (defined-but-empty) tells scripts/setlocalversion
# to skip the SCM-suffix branch. Without it, that script always
# appends `+` here because Microsoft tags as `linux-msft-wsl-X.Y.Z.W`
# (not `vX.Y.Z`), so its "exact-match-on-version-tag" check never
# succeeds and falls through to the `+` fallback. The running kernel
# ships without `+`, so a mismatch would make modprobe reject our
# modules with a vermagic error.
#
# HOSTCFLAGS=-Wno-error=discarded-qualifiers is a workaround for a
# strchr() const-cast in tools/bpf/resolve_btfids/libbpf/libbpf.c
# that newer GCCs (≥16) flag as -Werror. The kernel's own host-side
# Werror flips this fatal; older GCCs don't warn. Applying it
# unconditionally is harmless.
echo "build.sh: make -j$JOBS LOCALVERSION='' (vmlinux + modules — the slow step)"
make -j"$JOBS" LOCALVERSION="" \
     HOSTCFLAGS="-Wno-error=discarded-qualifiers"

VGEM_KO="$SRCDIR/drivers/gpu/drm/vgem/vgem.ko"
VKMS_KO="$SRCDIR/drivers/gpu/drm/vkms/vkms.ko"
[ -f "$VGEM_KO" ] || { echo "build.sh: vgem.ko missing"  >&2; exit 1; }
[ -f "$VKMS_KO" ] || { echo "build.sh: vkms.ko missing"  >&2; exit 1; }

# --- package -------------------------------------------------------
mkdir -p "$DIST"
PKG_NAME="vgem-vkms-modules-${TAG#linux-msft-wsl-}"
PKG_DIR="$DIST/$PKG_NAME"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"

cp "$VGEM_KO" "$VKMS_KO" "$PKG_DIR/"

# Manifest — useful for the consuming installer to verify vermagic
# before installing, and for human inspection of release artifacts.
VGEM_VERMAGIC=$(modinfo -F vermagic "$VGEM_KO" 2>/dev/null || echo "unknown")
VKMS_VERMAGIC=$(modinfo -F vermagic "$VKMS_KO" 2>/dev/null || echo "unknown")
KERNEL_RELEASE=$(awk -F'"' '/UTS_RELEASE/{print $2; exit}' "$SRCDIR/include/generated/utsrelease.h" 2>/dev/null || echo "unknown")

cat > "$PKG_DIR/manifest.txt" <<EOF
kernel-tag:      $TAG
kernel-release:  $KERNEL_RELEASE
vgem-vermagic:   $VGEM_VERMAGIC
vkms-vermagic:   $VKMS_VERMAGIC
built-at:        $(date -u +%Y-%m-%dT%H:%M:%SZ)
build-host:      ${RUNNER_OS:-$(uname -srm)}
EOF

TARBALL="$DIST/${PKG_NAME}.tar.gz"
tar -C "$DIST" -czf "$TARBALL" "$PKG_NAME"

echo "build.sh: produced $TARBALL"
echo "build.sh: kernel-release  = $KERNEL_RELEASE"
echo "build.sh: vgem vermagic   = $VGEM_VERMAGIC"
echo "build.sh: vkms vermagic   = $VKMS_VERMAGIC"
