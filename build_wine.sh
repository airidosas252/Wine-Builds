#!/usr/bin/env bash

########################################################################
##
## A script for building Wine (WoW64) for Termux Glibc / proot.
## Based on Kron4ek's build script, customized for Termux environments.
##
## Uses an Ubuntu Noble (24.04) bootstrap entered via bubblewrap.
## Supports x86_64 WoW64 and ARM64EC build architectures.
##
## Requirements: git, wget, autoconf, xz, bubblewrap
##
########################################################################

set -euo pipefail

########################################################################
## Prevent launching as root
########################################################################

if [ $EUID = 0 ] && [ -z "${ALLOW_ROOT:-}" ]; then
	echo "Do not run this script as root!"
	echo
	echo "If you really need to run it as root and you know what you are doing,"
	echo "set the ALLOW_ROOT environment variable."
	exit 1
fi

########################################################################
## Configuration
########################################################################

# Wine version to compile.
# Set to "latest" for the latest stable, "git" for latest git revision.
export WINE_VERSION="${WINE_VERSION:-latest}"

# Available branches: vanilla, staging, staging-tkg
export WINE_BRANCH="${WINE_BRANCH:-staging}"

# Build architecture: x86_64 (default) or arm64ec
export BUILD_ARCH="${BUILD_ARCH:-x86_64}"

# Target environment: termux-glibc or proot
# Set TERMUX_GLIBC=true for Termux native glibc environment.
# Set TERMUX_PROOT=true for proot/chroot environment.
# These two cannot both be true.
export TERMUX_GLIBC="${TERMUX_GLIBC:-false}"
export TERMUX_PROOT="${TERMUX_PROOT:-false}"

# Custom staging arguments for patchinstall.sh.
# Leave empty to use the defaults per-branch.
export STAGING_ARGS="${STAGING_ARGS:-}"

# Sometimes Wine and Staging versions don't match (for example, 5.15.2).
# Leave empty to use Staging version that matches the Wine version.
export STAGING_VERSION="${STAGING_VERSION:-}"

# Set to a path or git URL for custom Wine source code.
export CUSTOM_SRC_PATH=""

# Set to true to download/patch only, without compiling.
export DO_NOT_COMPILE="false"

# Set to true to use ccache for faster recompilation.
export USE_CCACHE="${USE_CCACHE:-false}"

# Wine configure options
export WINE_BUILD_OPTIONS="--disable-winemenubuilder --disable-win16 --disable-tests --without-capi --without-coreaudio --without-cups --without-gphoto --without-osmesa --without-oss --without-pcap --without-pcsclite --without-sane --without-udev --without-unwind --without-usb --without-v4l2 --without-wayland --without-xinerama"

# Build directory (temporary, recreated each run)
export BUILD_DIR="${HOME}/build_wine"

########################################################################
## Derived paths
########################################################################

export scriptdir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
export BOOTSTRAP_X64=/opt/chroots/noble64_chroot

########################################################################
## Architecture-specific compiler setup
########################################################################

if [ "${BUILD_ARCH}" = "arm64ec" ]; then
	echo "==> ARM64EC build mode"

	LLVM_MINGW_VERSION="20250920"
	LLVM_MINGW_ARCHIVE="llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-x86_64"
	LLVM_MINGW_URL="https://github.com/bylaws/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/${LLVM_MINGW_ARCHIVE}.tar.xz"

	# Host compiler = aarch64 cross-compiler (produces native ARM64 binaries)
	export CC="aarch64-linux-gnu-gcc-14"
	export CXX="aarch64-linux-gnu-g++-14"

	# Tell pkg-config to find aarch64 libraries
	export PKG_CONFIG_PATH="/usr/lib/aarch64-linux-gnu/pkgconfig"
	export PKG_CONFIG_LIBDIR="/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig"

	WINE_ARCH_FLAGS="--enable-archs=arm64ec,aarch64,i386 --with-mingw=clang --host=aarch64-linux-gnu"
else
	echo "==> x86_64 WoW64 build mode"

	export CC="gcc-14"
	export CXX="g++-14"

	export CROSSCC_X64="x86_64-w64-mingw32-gcc"
	export CROSSCXX_X64="x86_64-w64-mingw32-g++"

	export CFLAGS_X64="-march=x86-64 -msse3 -mfpmath=sse -O3 -ftree-vectorize -pipe"
	export LDFLAGS="-Wl,-O1,--sort-common,--as-needed"

	export CROSSCFLAGS_X64="${CFLAGS_X64}"
	export CROSSLDFLAGS="${LDFLAGS}"

	WINE_ARCH_FLAGS="--enable-archs=i386,x86_64"

	if [ "${USE_CCACHE}" = "true" ]; then
		export CC="ccache ${CC}"
		export CXX="ccache ${CXX}"
		export x86_64_CC="ccache ${CROSSCC_X64}"
		export CROSSCC_X64="ccache ${CROSSCC_X64}"
		export CROSSCXX_X64="ccache ${CROSSCXX_X64}"

		# Use BUILD_DIR for ccache so it's accessible inside bwrap
		# (bwrap uses --tmpfs /home which wipes ~/.ccache)
		export CCACHE_DIR="${BUILD_DIR}/ccache_cache"
		mkdir -p "${CCACHE_DIR}"
	fi
fi

########################################################################
## Bubblewrap build function
########################################################################

build_with_bwrap () {
	bwrap --ro-bind "${BOOTSTRAP_X64}" / --dev /dev --ro-bind /sys /sys \
		--proc /proc --tmpfs /tmp --tmpfs /home --tmpfs /run --tmpfs /var \
		--tmpfs /mnt --tmpfs /media --bind "${BUILD_DIR}" "${BUILD_DIR}" \
		--setenv PATH "/bin:/sbin:/usr/bin:/usr/sbin:${PATH}" \
		--setenv CCACHE_DIR "${CCACHE_DIR:-/tmp/ccache}" \
		"$@"
}

########################################################################
## Environment validation
########################################################################

if [ "${TERMUX_PROOT}" = "true" ] && [ "${TERMUX_GLIBC}" = "true" ]; then
	echo "ERROR: Only TERMUX_PROOT or TERMUX_GLIBC can be set at the same time."
	exit 1
fi

if [ "${TERMUX_PROOT}" = "true" ]; then
	echo "==> Building Wine for proot/chroot environment"
elif [ "${TERMUX_GLIBC}" = "true" ]; then
	echo "==> Building Wine for Termux glibc native environment"
fi

########################################################################
## Dependency checks
########################################################################

for cmd in git autoconf wget xz; do
	if ! command -v "${cmd}" 1>/dev/null; then
		echo "Please install ${cmd} and run the script again"
		exit 1
	fi
done

########################################################################
## Resolve Wine version
########################################################################

if [ "${WINE_VERSION}" = "latest" ] || [ -z "${WINE_VERSION}" ]; then
	WINE_VERSION="$(wget -q -O - "https://raw.githubusercontent.com/wine-mirror/wine/master/VERSION" | tail -c +14)"
fi

# Determine stable vs development source URL
WINE_MAJOR="$(echo "$WINE_VERSION" | cut -d. -f1)"
WINE_MINOR="$(echo "$WINE_VERSION" | cut -d. -f2)"
if [ "${WINE_MINOR}" = "0" ]; then
	WINE_URL_VERSION="${WINE_MAJOR}.0"
else
	WINE_URL_VERSION="${WINE_MAJOR}.x"
fi

########################################################################
## Prepare build directory
########################################################################

# Preserve ccache across BUILD_DIR recreation
if [ "${USE_CCACHE}" = "true" ] && [ -d "${BUILD_DIR}/ccache_cache" ]; then
	cp -a "${BUILD_DIR}/ccache_cache" /tmp/ccache_save
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Restore preserved ccache
if [ "${USE_CCACHE}" = "true" ] && [ -d /tmp/ccache_save ]; then
	mv /tmp/ccache_save "${BUILD_DIR}/ccache_cache"
fi

cd "${BUILD_DIR}" || exit 1

echo
echo "==> Downloading source code and patches"
echo "==> Preparing Wine for compilation"
echo

########################################################################
## Download Wine source code
########################################################################

if [ -n "${CUSTOM_SRC_PATH}" ]; then
	is_url="$(echo "${CUSTOM_SRC_PATH}" | head -c 6)"

	if [ "${is_url}" = "git://" ] || [ "${is_url}" = "https:" ]; then
		git clone "${CUSTOM_SRC_PATH}" wine
	else
		if [ ! -f "${CUSTOM_SRC_PATH}/configure" ]; then
			echo "CUSTOM_SRC_PATH is set to an incorrect or non-existent directory!"
			exit 1
		fi
		cp -r "${CUSTOM_SRC_PATH}" wine
	fi

	WINE_VERSION="$(cat wine/VERSION | tail -c +14)"
	BUILD_NAME="${WINE_VERSION}-custom"

elif [ "$WINE_BRANCH" = "staging-tkg" ]; then
	git clone https://github.com/Kron4ek/wine-tkg wine
	WINE_VERSION="$(cat wine/VERSION | tail -c +14)"
	BUILD_NAME="${WINE_VERSION}-staging-tkg"

elif [ "$WINE_BRANCH" = "vanilla" ] || [ "$WINE_BRANCH" = "staging" ]; then
	if [ "${WINE_VERSION}" = "git" ]; then
		git clone https://gitlab.winehq.org/wine/wine.git wine
		BUILD_NAME="${WINE_VERSION}-$(git -C wine rev-parse --short HEAD)"
	else
		BUILD_NAME="${WINE_VERSION}"
		wget -q --show-progress "https://dl.winehq.org/wine/source/${WINE_URL_VERSION}/wine-${WINE_VERSION}.tar.xz"
		tar xf "wine-${WINE_VERSION}.tar.xz"
		mv "wine-${WINE_VERSION}" wine
	fi

	# Download Wine-Staging patches
	if [ "${WINE_VERSION}" = "git" ]; then
		git clone https://github.com/wine-staging/wine-staging wine-staging-"${WINE_VERSION}"
		upstream_commit="$(cat wine-staging-"${WINE_VERSION}"/staging/upstream-commit | head -c 7)"
		git -C wine checkout "${upstream_commit}"
		if [ "$WINE_BRANCH" = "vanilla" ]; then
			BUILD_NAME="${WINE_VERSION}-${upstream_commit}"
		else
			BUILD_NAME="${WINE_VERSION}-${upstream_commit}-staging"
		fi
	else
		if [ -n "${STAGING_VERSION}" ]; then
			WINE_VERSION="${STAGING_VERSION}"
		fi

		if [ "${WINE_BRANCH}" = "staging" ]; then
			BUILD_NAME="${WINE_VERSION}-staging"
		fi

		wget -q --show-progress "https://github.com/wine-staging/wine-staging/archive/v${WINE_VERSION}.tar.gz"
		tar xf v"${WINE_VERSION}".tar.gz

		if [ ! -f v"${WINE_VERSION}".tar.gz ]; then
			git clone https://github.com/wine-staging/wine-staging wine-staging-"${WINE_VERSION}"
		fi
	fi

	# Determine staging patcher path
	if [ -f wine-staging-"${WINE_VERSION}"/patches/patchinstall.sh ]; then
		staging_patcher=("${BUILD_DIR}"/wine-staging-"${WINE_VERSION}"/patches/patchinstall.sh
			DESTDIR="${BUILD_DIR}"/wine)
	else
		staging_patcher=("${BUILD_DIR}"/wine-staging-"${WINE_VERSION}"/staging/patchinstall.py)
	fi

	########################################################################
	## Determine Wine-Staging patch arguments
	########################################################################

	if [ "${WINE_BRANCH}" = "staging" ]; then
		STAGING_ARGS="${STAGING_ARGS:---all -W ntdll-Syscall_Emulation}"
	elif [ "${WINE_BRANCH}" = "vanilla" ]; then
		# eventfd_synchronization only exists in Wine-Staging <= 10.10
		# Wine 10.11+ disabled it, Wine 10.16+ removed it entirely
		_major="$(echo "${WINE_VERSION}" | cut -d. -f1)"
		_minor="$(echo "${WINE_VERSION}" | cut -d. -f2)"
		if [ "${_major}" -le 10 ] 2>/dev/null && [ "${_minor}" -le 10 ] 2>/dev/null; then
			STAGING_ARGS="${STAGING_ARGS:-eventfd_synchronization}"
			echo "    Wine ${WINE_VERSION}: applying eventfd_synchronization patches"
		else
			STAGING_ARGS=""
			echo "    Wine ${WINE_VERSION}: eventfd not available, skipping Staging patches"
		fi
	fi

	########################################################################
	## Apply Wine-Staging patches
	########################################################################

	cd wine || exit 1
	if [ -n "${STAGING_ARGS}" ]; then
		"${staging_patcher[@]}" ${STAGING_ARGS}
	else
		echo "Skipping Wine-Staging patches..."
	fi

	if [ $? -ne 0 ]; then
		echo
		echo "Wine-Staging patches were not applied correctly!"
		exit 1
	fi

	cd "${BUILD_DIR}" || exit 1
else
	echo "Unknown Wine branch: ${WINE_BRANCH}"
	exit 1
fi

########################################################################
## Apply proot address space patch
########################################################################

if [ "${TERMUX_PROOT}" = "true" ]; then
	echo "==> Applying address space patch for proot/chroot..."
	patch -d wine -Np1 < "${scriptdir}"/patches/proot/address-space-proot.patch || {
		echo "Error: Failed to apply proot address space patch."
		exit 1
	}
fi

########################################################################
## Apply Termux Glibc patches
########################################################################

if [ "${TERMUX_GLIBC}" = "true" ]; then
	echo "==> Applying Termux Glibc patches for branch: ${WINE_BRANCH}"

	# Extract major.minor version for version-specific patches (e.g., "10.10" from "10.10" or "11.4")
	WINE_MAJOR_MINOR="$(echo "${WINE_VERSION}" | grep -oP '^\d+\.\d+')"
	echo "    Wine version for patch matching: ${WINE_MAJOR_MINOR:-unknown}"

	# Apply common patches (universal — patches/common/*.patch)
	for patch_file in "${scriptdir}"/patches/common/*.patch; do
		if [ -f "${patch_file}" ]; then
			echo "  Applying common patch: $(basename "${patch_file}")"
			patch -d wine -Np1 < "${patch_file}" || {
				echo "Error: Failed to apply $(basename "${patch_file}")"
				exit 1
			}
		fi
	done

	# Apply version-specific common patches (patches/common/<version>/*.patch)
	if [ -n "${WINE_MAJOR_MINOR}" ] && [ -d "${scriptdir}/patches/common/${WINE_MAJOR_MINOR}" ]; then
		for patch_file in "${scriptdir}"/patches/common/"${WINE_MAJOR_MINOR}"/*.patch; do
			if [ -f "${patch_file}" ]; then
				echo "  Applying common ${WINE_MAJOR_MINOR} patch: $(basename "${patch_file}")"
				patch -d wine -Np1 < "${patch_file}" || {
					echo "Error: Failed to apply $(basename "${patch_file}")"
					exit 1
				}
			fi
		done
	fi

	# Apply branch-specific patches (universal — patches/<branch>/*.patch)
	if [ -d "${scriptdir}/patches/${WINE_BRANCH}" ]; then
		for patch_file in "${scriptdir}"/patches/"${WINE_BRANCH}"/*.patch; do
			if [ -f "${patch_file}" ]; then
				echo "  Applying ${WINE_BRANCH} patch: $(basename "${patch_file}")"
				patch -d wine -Np1 < "${patch_file}" || {
					echo "Error: Failed to apply $(basename "${patch_file}")"
					exit 1
				}
			fi
		done
	fi

	# Apply version-specific branch patches (patches/<branch>/<version>/*.patch)
	if [ -n "${WINE_MAJOR_MINOR}" ] && [ -d "${scriptdir}/patches/${WINE_BRANCH}/${WINE_MAJOR_MINOR}" ]; then
		for patch_file in "${scriptdir}"/patches/"${WINE_BRANCH}"/"${WINE_MAJOR_MINOR}"/*.patch; do
			if [ -f "${patch_file}" ]; then
				echo "  Applying ${WINE_BRANCH} ${WINE_MAJOR_MINOR} patch: $(basename "${patch_file}")"
				patch -d wine -Np1 < "${patch_file}" || {
					echo "Error: Failed to apply $(basename "${patch_file}")"
					exit 1
				}
			fi
		done
	fi
fi

cd wine || exit 1

########################################################################
## Run Wine code generators
########################################################################

dlls/winevulkan/make_vulkan
tools/make_requests
tools/make_specfiles
autoreconf -f

cd "${BUILD_DIR}" || exit 1

########################################################################
## Early exit if DO_NOT_COMPILE
########################################################################

if [ "${DO_NOT_COMPILE}" = "true" ]; then
	echo "DO_NOT_COMPILE is set to true — exiting after source prep."
	exit 0
fi

########################################################################
## Validate build environment
########################################################################

if ! command -v bwrap 1>/dev/null; then
	echo "Bubblewrap is not installed! Please install it and run the script again."
	exit 1
fi

if [ ! -d "${BOOTSTRAP_X64}" ]; then
	echo "Bootstrap not found at ${BOOTSTRAP_X64}!"
	echo "Run create_bootstrap.sh first."
	exit 1
fi

if [ ! -d wine ]; then
	echo "No Wine source code found!"
	echo "Make sure that the correct Wine version is specified."
	exit 1
fi

########################################################################
## ARM64EC toolchain setup
########################################################################

if [ "${BUILD_ARCH}" = "arm64ec" ]; then
	echo "==> Downloading bylaws/llvm-mingw toolchain..."
	cd "${BUILD_DIR}"
	wget -q --show-progress -O llvm-mingw.tar.xz "${LLVM_MINGW_URL}"
	tar xf llvm-mingw.tar.xz
	# MUST be first in PATH — overrides host 'ar' binary
	export PATH="${BUILD_DIR}/${LLVM_MINGW_ARCHIVE}/bin:${PATH}"
	echo "==> llvm-mingw toolchain ready"
fi

########################################################################
## Compile Wine
########################################################################

echo
echo "==> Starting Wine compilation (${BUILD_ARCH})"
echo

if [ "${BUILD_ARCH}" = "arm64ec" ]; then
	mkdir "${BUILD_DIR}"/build64
	cd "${BUILD_DIR}"/build64 || exit 1
	build_with_bwrap "${BUILD_DIR}"/wine/configure \
		${WINE_ARCH_FLAGS} \
		${WINE_BUILD_OPTIONS} \
		--prefix "${BUILD_DIR}"/wine-"${BUILD_NAME}"-arm64ec
	build_with_bwrap make -j$(nproc)
	build_with_bwrap make install
else
	export CROSSCC="${CROSSCC_X64}"
	export CROSSCXX="${CROSSCXX_X64}"
	export CFLAGS="${CFLAGS_X64}"
	export CXXFLAGS="${CFLAGS_X64}"
	export CROSSCFLAGS="${CROSSCFLAGS_X64}"
	export CROSSCXXFLAGS="${CROSSCFLAGS_X64}"

	mkdir "${BUILD_DIR}"/build64
	cd "${BUILD_DIR}"/build64 || exit 1
	build_with_bwrap "${BUILD_DIR}"/wine/configure \
		${WINE_ARCH_FLAGS} \
		${WINE_BUILD_OPTIONS} \
		--prefix "${BUILD_DIR}"/wine-"${BUILD_NAME}"-amd64
	build_with_bwrap make -j$(nproc)
	build_with_bwrap make install
fi

########################################################################
## Package the build
########################################################################

echo
echo "==> Compilation complete"
echo "==> Creating and compressing archives..."

cd "${BUILD_DIR}" || exit 1

if touch "${scriptdir}"/write_test 2>/dev/null; then
	rm -f "${scriptdir}"/write_test
	result_dir="${scriptdir}"
else
	result_dir="${HOME}"
fi

export XZ_OPT="-9"

if [ "${BUILD_ARCH}" = "arm64ec" ]; then
	builds_list="wine-${BUILD_NAME}-arm64ec"
else
	builds_list="wine-${BUILD_NAME}-amd64"
fi

for build in ${builds_list}; do
	if [ -d "${build}" ]; then
		rm -rf "${build}"/include "${build}"/share/applications "${build}"/share/man

		if [ -f wine/wine-tkg-config.txt ]; then
			cp wine/wine-tkg-config.txt "${build}"
		fi

		tar -Jcf "${build}".tar.xz "${build}"
		mv "${build}".tar.xz "${result_dir}"
	fi
done

# Preserve ccache before cleanup
if [ "${USE_CCACHE}" = "true" ] && [ -d "${BUILD_DIR}/ccache_cache" ]; then
	echo "==> Saving ccache ($(du -sh "${BUILD_DIR}/ccache_cache" | cut -f1))..."
	cp -a "${BUILD_DIR}/ccache_cache" /tmp/ccache_save
fi

rm -rf "${BUILD_DIR}"

# Restore ccache to ~/.ccache for GitHub Actions cache persistence
if [ "${USE_CCACHE}" = "true" ] && [ -d /tmp/ccache_save ]; then
	mkdir -p "${HOME}/.ccache"
	cp -a /tmp/ccache_save/* "${HOME}/.ccache/" 2>/dev/null || true
	rm -rf /tmp/ccache_save
fi

echo
echo "Done"
echo "The builds should be in ${result_dir}"
