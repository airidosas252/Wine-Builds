## Introduction

This is a repurposed Wine build script originally made by Kron4ek, modified for building Wine in Termux Glibc and proot/chroot environments. It uses the new WoW64 mode exclusively (`--enable-archs=i386,x86_64`).

Key features:
- Builds Wine for **Termux glibc** or **proot/chroot** environments
- Supports **x86_64 WoW64** build architecture
- Optional **Wayland** support via `BUILD_WAYLAND` toggle
- Uses Ubuntu Noble (24.04) bootstrap with bubblewrap sandboxing
- Available branches: **vanilla**, **staging**, **staging-tkg**
- Organized patch system with per-branch patch directories

**NOTE** - it does not currently support **Proton** branch or any of it's forks.

## Download

Builds are available on the [GitHub Actions](../../actions) page. Make sure you are logged in, otherwise artifacts will be grayed out.

---

## Quick Start

### 1. Create the bootstrap (one-time setup)

```bash
sudo apt install debootstrap perl
sudo ./create_bootstrap.sh
```

### 2. Build Wine

```bash
# Default: staging, x86_64, termux-glibc
./build_wine.sh

# Vanilla build for proot
WINE_BRANCH=vanilla TERMUX_GLIBC=false TERMUX_PROOT=true ./build_wine.sh

# Build with Wayland support
BUILD_WAYLAND=true ./build_wine.sh

# Specific version
WINE_VERSION=9.0 WINE_BRANCH=vanilla ./build_wine.sh
```

---

## Configuration

| Variable | Default | Description |
|---|---|---|
| `WINE_VERSION` | `latest` | Wine version (`latest`, `git`, or specific like `9.0`) |
| `WINE_BRANCH` | `staging` | Build branch: `vanilla`, `staging`, `staging-tkg` |
| `BUILD_WAYLAND` | `false` | Set to `true` to build with Wayland support |
| `TERMUX_GLIBC` | `false` | Set to `true` for Termux native glibc environment |
| `TERMUX_PROOT` | `false` | Set to `true` for proot/chroot environment |
| `USE_CCACHE` | `false` | Enable ccache for faster recompilation |
| `DO_NOT_COMPILE` | `false` | Download/patch only, skip compilation |

---

## Build Architecture

### x86_64 WoW64

- Configure: `--enable-archs=i386,x86_64`
- Compiler: `gcc-14` + `x86_64-w64-mingw32-gcc`
- Build flags: `-march=x86-64 -msse3 -mfpmath=sse -O3 -ftree-vectorize`

---

## Patches

Patches are organized in the `patches/` directory. Version-specific patches live in subdirectories (e.g., `vanilla/10.10/`):

| Directory | Purpose |
|---|---|
| `patches/common/` | Applied to all branches |
| `patches/common/{version}/` | Version-specific common patches (e.g., `wine-virtual-memory`) |
| `patches/vanilla/` | Vanilla-specific (termux-wine-fix) |
| `patches/vanilla/{version}/` | Version-specific vanilla patches (e.g., `esync`, `path-patch-universal`) |
| `patches/staging/` | Staging-specific (esync, termux-wine-fix-staging) |
| `patches/staging-tkg/` | Staging-TkG-specific |
| `patches/proot/` | Applied when building for proot (address-space-proot) |
| `patches/deprecated/` | Old/unused patches kept for reference |

---

## Wine Runtime Environment Variables

The `path-patch-universal` patch adds three environment variables to customize Wine paths at runtime:

| Variable | Default | Description |
|---|---|---|
| `WINE_TMP_DIR` | `/data/data/com.termux/files/usr/tmp` | Temp directory for wineserver socket and working files |
| `WINE_CA_CERT_PATH` | `/data/data/com.termux/files/usr/glibc/etc/ca-certificates/cacert.pem` | Path to CA certificates for SSL/TLS |
| `WINE_SHARE_DIRS` | `/data/data/com.termux/files/usr/glibc/local/share:/data/data/com.termux/files/usr/glibc/share` | XDG data directories for MIME types |

---

## Requirements

- glibc 2.27 or newer
- All regular Wine dependencies (install Wine from your distro's repos for the easiest setup)
- Build tools: `git`, `wget`, `autoconf`, `xz`, `bubblewrap`

---

## GitHub Actions

Two workflows handle CI:

| Workflow | Purpose | Trigger |
|---|---|---|
| `bootstrap.yml` | Creates the Ubuntu Noble bootstrap | Bi-monthly + manual |
| `build-wine.yml` | Builds Wine with configurable branch/arch/env | Every 3 days + manual |

The build workflow accepts inputs for `wine_branch`, `wine_version`, `target_env`, and `build_wayland`.

---

## Available Branches

* **Vanilla** — compiled from official WineHQ sources, with esync patches cherry-picked from Staging.
* **Staging** — Wine with [the Staging patchset](https://github.com/wine-staging/wine-staging) applied.
* **Staging-TkG** — Wine with Staging and additional TkG patches. Compiled from [wine-tkg source](https://github.com/Kron4ek/wine-tkg).

---

### Links to Sources

* https://dl.winehq.org/wine/source
* https://github.com/wine-staging/wine-staging
* https://github.com/Frogging-Family/wine-tkg-git
* https://github.com/Kron4ek/wine-tkg

### Credits

Big thanks to: Kron4ek (original build script), Olegos, JeezDisReez, Hugo, askorbinovaya_kislota, and the FEX-Emu team.
