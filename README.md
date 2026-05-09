# wsl-renderd-modules

> ⚠️ **Experimental.** Auto-built kernel modules for use with WSL2's stock Microsoft kernel. Each release contains `vgem.ko` + `vkms.ko` whose vermagic matches the corresponding Microsoft WSL2 kernel exactly. No warranty — read the code before loading kernel modules.

A small companion project for [wsl-gnome-rdp-installer](https://github.com/techneut92/wsl-gnome-rdp-installer): builds `vgem.ko` and `vkms.ko` against Microsoft's WSL2 kernel source so they can be `modprobe`'d into any WSL2 distro to expose `/dev/dri/renderD128`.

## Why

Microsoft's stock WSL2 kernel ships with `CONFIG_DRM=y` and `CONFIG_MODULES=y` but neither VGEM nor VKMS enabled. Apps that gate features on a DRM render node existing — PipeWire dma-buf screen capture (`xdg-desktop-portal-gnome`, OBS), some Wayland clients, EGL device-platform consumers, browsers' GPU sandboxing checks — silently disable themselves on stock WSL2.

You can patch this by:

1. **Rebuilding the whole kernel with `CONFIG_DRM_VGEM=y`/`VKMS=y` and pinning it via `.wslconfig`** — heavy (~10 min build), pins you to a stale kernel until you rebuild.
2. **Building just `vgem.ko` + `vkms.ko` as out-of-tree modules and `modprobe`'ing them** — fast (~30s build), no `.wslconfig` change, Microsoft's WSL kernel updates flow through normally.

This repo automates option 2 in CI and publishes the .ko's as GitHub Releases. The downstream installer pulls the matching tarball and drops the modules into `/lib/modules/$(uname -r)/extra/`.

## What this is NOT

- **Not GPU acceleration.** VGEM is a virtual driver — apps using it still render via llvmpipe (CPU). It only unblocks code paths that disable themselves when no render node exists.
- **Not a kernel patch.** No source changes, just stock upstream drivers built as modules against Microsoft's stock config.

## Releases

Each release is named after a Microsoft WSL2 kernel tag (e.g. `linux-msft-wsl-6.18.26.1`). The release asset is a tarball containing:

```
vgem-vkms-modules-6.18.26.1/
├── vgem.ko
├── vkms.ko
└── manifest.txt
```

`manifest.txt` records the kernel tag, the resulting `vermagic` string, build timestamp, and runner OS so you can verify before loading.

## Local build

```bash
./build.sh latest                       # newest tag from upstream
./build.sh linux-msft-wsl-6.18.26.1     # specific tag
```

Output lands in `dist/`. Build deps (Debian/Ubuntu): `build-essential bison flex bc libelf-dev libssl-dev libncurses-dev python3 dwarves cpio xz-utils tar perl`.

The script is identical to what runs in CI — `.github/workflows/build.yml` is just `apt-get install <deps>` + `./build.sh latest` + `gh release create`. So your local artifact is byte-comparable to the published one.

## CI

`.github/workflows/build.yml` runs:

- on push (when `build.sh` or the workflow itself changes),
- weekly Mondays at 04:00 UTC (catches new Microsoft kernel tags),
- on manual dispatch (with optional tag override).

It resolves the latest `linux-msft-wsl-*` tag, skips if a release for that tag already exists, otherwise builds + releases. Idempotent.

## How `vermagic` works (and why this is portable)

Linux kernel modules embed a `vermagic` string at build time, e.g. `6.18.26.1-microsoft-standard-WSL2 SMP preempt mod_unload modversions`. `modprobe` checks this against the running kernel's value and rejects the load on mismatch.

`vermagic` is determined by:

- `UTS_RELEASE` (kernel version, set by the kernel source's git tag)
- `MODULE_VERMAGIC_SMP` / `_PREEMPT` / `_MODULE_UNLOAD` / `_MODVERSIONS` (kernel `.config` flags)

It is **not** affected by:

- The build host's distro
- The build host's `gcc` version
- The current host's running kernel

So modules built against `linux-msft-wsl-X.Y.Z.W` on Ubuntu 24.04 (the GitHub Actions runner) load on any WSL2 distro — Fedora, Debian, Ubuntu, openSUSE, Arch — running Microsoft's matching stock kernel. No per-distro builds needed.

## License

MIT — see [LICENSE](LICENSE). The kernel sources we build against are GPL-2.0; the resulting modules are derivative works subject to GPL-2.0.
