#!/usr/bin/env bash

## A script for creating an Ubuntu bootstrap for Wine WoW64 compilation.
## This bootstrap provides a 64-bit build environment using bubblewrap.
##
## Requirements: debootstrap, perl, root rights
## About 5.5 GB of free space is required
## Additional 2.5 GB is required for Wine compilation

set -euo pipefail

if [ "$EUID" != 0 ]; then
	echo "This script requires root rights!"
	exit 1
fi

if ! command -v debootstrap 1>/dev/null || ! command -v perl 1>/dev/null; then
	echo "Please install debootstrap and perl and run the script again"
	exit 1
fi

######################################################################
## Configuration
######################################################################

export CHROOT_DISTRO="noble"
export CHROOT_MIRROR="https://ftp.uni-stuttgart.de/ubuntu/"
export MAINDIR=/opt/chroots
export CHROOT_X64="${MAINDIR}"/${CHROOT_DISTRO}64_chroot

######################################################################
## Library versions for custom builds inside chroot
######################################################################

sdl2_version="2.30.2"
faudio_version="24.05"
vulkan_headers_version="1.3.285"
vulkan_loader_version="1.3.285"
spirv_headers_version="vulkan-sdk-1.3.283.0"
libpcap_version="1.10.4"
vkd3d_version="1.11"

######################################################################
## Functions
######################################################################

prepare_chroot () {
	CHROOT_PATH="${CHROOT_X64}"

	echo "Unmount chroot directories. Just in case."
	umount -Rl "${CHROOT_PATH}" 2>/dev/null || true

	echo "Mount directories for chroot"
	mount --bind "${CHROOT_PATH}" "${CHROOT_PATH}"
	mount -t proc /proc "${CHROOT_PATH}"/proc
	mount --bind /sys "${CHROOT_PATH}"/sys
	mount --make-rslave "${CHROOT_PATH}"/sys
	mount --bind /dev "${CHROOT_PATH}"/dev
	mount --bind /dev/pts "${CHROOT_PATH}"/dev/pts
	mount --bind /dev/shm "${CHROOT_PATH}"/dev/shm
	mount --make-rslave "${CHROOT_PATH}"/dev

	rm -f "${CHROOT_PATH}"/etc/resolv.conf
	cp /etc/resolv.conf "${CHROOT_PATH}"/etc/resolv.conf

	echo "Chrooting into ${CHROOT_PATH}"
	chroot "${CHROOT_PATH}" /usr/bin/env LANG=en_US.UTF-8 TERM=xterm PATH="/bin:/sbin:/usr/bin:/usr/sbin" /opt/prepare_chroot.sh

	echo "Unmount chroot directories"
	umount -l "${CHROOT_PATH}"
	umount "${CHROOT_PATH}"/proc
	umount "${CHROOT_PATH}"/sys
	umount "${CHROOT_PATH}"/dev/pts
	umount "${CHROOT_PATH}"/dev/shm
	umount "${CHROOT_PATH}"/dev
}

create_build_scripts () {
	cat <<EOF > "${MAINDIR}"/prepare_chroot.sh
#!/bin/bash
set -e

apt-get update
apt-get -y install nano locales
echo ru_RU.UTF_8 UTF-8 >> /etc/locale.gen
echo en_US.UTF_8 UTF-8 >> /etc/locale.gen
locale-gen

echo deb '${CHROOT_MIRROR}' ${CHROOT_DISTRO} main universe > /etc/apt/sources.list
echo deb '${CHROOT_MIRROR}' ${CHROOT_DISTRO}-updates main universe >> /etc/apt/sources.list
echo deb '${CHROOT_MIRROR}' ${CHROOT_DISTRO}-security main universe >> /etc/apt/sources.list
echo deb-src '${CHROOT_MIRROR}' ${CHROOT_DISTRO} main universe >> /etc/apt/sources.list
echo deb-src '${CHROOT_MIRROR}' ${CHROOT_DISTRO}-updates main universe >> /etc/apt/sources.list
echo deb-src '${CHROOT_MIRROR}' ${CHROOT_DISTRO}-security main universe >> /etc/apt/sources.list

apt-get update
apt-get -y upgrade
apt-get -y dist-upgrade

apt-get -y install software-properties-common

apt-get update
apt-get -y build-dep wine-development libsdl2 libvulkan1

apt-get -y install cmake flex bison ccache gcc-14 g++-14 wget git gcc-mingw-w64 g++-mingw-w64
apt-get -y install libxpresent-dev libjxr-dev libusb-1.0-0-dev libgcrypt20-dev libpulse-dev libudev-dev libsane-dev libv4l-dev libkrb5-dev libgphoto2-dev liblcms2-dev libcapi20-dev
apt-get -y install libjpeg62-dev samba-dev libfreetype-dev libunwind-dev ocl-icd-opencl-dev libgnutls28-dev libx11-dev libxcomposite-dev libxcursor-dev libxfixes-dev libxi-dev libxrandr-dev
apt-get -y install libxrender-dev libxext-dev libpcsclite-dev libcups2-dev libosmesa6-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
apt-get -y install python3-pip libxcb-xkb-dev libfontconfig-dev libgl-dev libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libswresample-dev libavfilter-dev
apt-get -y install meson ninja-build libxml2 libxml2-dev libxkbcommon-dev libxkbcommon0 xkb-data libxxf86vm-dev libdbus-1-dev

apt-get -y purge libvulkan-dev libvulkan1 libsdl2-dev libsdl2-2.0-0 libpcap0.8-dev libpcap0.8 --purge --autoremove
apt-get -y clean
apt-get -y autoclean

export PATH="/usr/local/bin:\${PATH}"

mkdir /opt/build_libs
cd /opt/build_libs

# Download custom library sources
wget -O sdl.tar.gz https://www.libsdl.org/release/SDL2-${sdl2_version}.tar.gz
wget -O faudio.tar.gz https://github.com/FNA-XNA/FAudio/archive/${faudio_version}.tar.gz
wget -O vulkan-loader.tar.gz https://github.com/KhronosGroup/Vulkan-Loader/archive/v${vulkan_loader_version}.tar.gz
wget -O vulkan-headers.tar.gz https://github.com/KhronosGroup/Vulkan-Headers/archive/v${vulkan_headers_version}.tar.gz
wget -O spirv-headers.tar.gz https://github.com/KhronosGroup/SPIRV-Headers/archive/refs/tags/${spirv_headers_version}.tar.gz
wget -O libpcap.tar.gz https://www.tcpdump.org/release/libpcap-${libpcap_version}.tar.gz

# Wine widl binary (needed for vkd3d build)
if [ -d /usr/lib/x86_64-linux-gnu ]; then
	wget -O wine.deb https://dl.winehq.org/wine-builds/ubuntu/dists/jammy/main/binary-amd64/wine-stable_9.0.0.0~jammy-1_amd64.deb
fi

# VkD3D
wget -O vkd3d.tar.xz https://dl.winehq.org/vkd3d/source/vkd3d-${vkd3d_version}.tar.xz
tar xf vkd3d.tar.xz
mv vkd3d-${vkd3d_version} vkd3d

# Extract all sources
tar xf sdl.tar.gz
tar xf faudio.tar.gz
tar xf vulkan-loader.tar.gz
tar xf vulkan-headers.tar.gz
tar xf spirv-headers.tar.gz
tar xf libpcap.tar.gz

export CFLAGS="-O2"
export CXXFLAGS="-O2"

# Build SDL2
mkdir build && cd build
cmake ../SDL2-${sdl2_version} && make -j\$(nproc) && make install

# Build FAudio
cd ../ && rm -r build && mkdir build && cd build
cmake ../FAudio-${faudio_version} && make -j\$(nproc) && make install

# Build Vulkan Headers
cd ../ && rm -r build && mkdir build && cd build
cmake ../Vulkan-Headers-${vulkan_headers_version} && make -j\$(nproc) && make install

# Build Vulkan Loader
cd ../ && rm -r build && mkdir build && cd build
cmake ../Vulkan-Loader-${vulkan_loader_version}
make -j\$(nproc)
make install

# Build SPIRV Headers
cd ../ && rm -r build && mkdir build && cd build
cmake ../SPIRV-Headers-${spirv_headers_version} && make -j\$(nproc) && make install

# Extract widl from Wine .deb
cd ../ && dpkg -x wine.deb .
cp opt/wine-stable/bin/widl /usr/bin

# Build VkD3D
cd vkd3d
cd ../ && rm -r build && mkdir build && cd build
../vkd3d/configure && make -j\$(nproc) && make install

# Build libpcap
cd ../ && rm -r build && mkdir build && cd build
../libpcap-${libpcap_version}/configure && make -j\$(nproc) install

# Cleanup
cd /opt && rm -r /opt/build_libs
EOF

	chmod +x "${MAINDIR}"/prepare_chroot.sh
	cp "${MAINDIR}"/prepare_chroot.sh "${CHROOT_X64}"/opt
}

######################################################################
## Main
######################################################################

echo "Creating WoW64 bootstrap (Ubuntu ${CHROOT_DISTRO} amd64)"
echo "Output: ${CHROOT_X64}"
echo

mkdir -p "${MAINDIR}"

debootstrap --arch amd64 $CHROOT_DISTRO "${CHROOT_X64}" $CHROOT_MIRROR

create_build_scripts
prepare_chroot

rm "${CHROOT_X64}"/opt/prepare_chroot.sh

clear
echo "Done"
echo "Bootstrap created at: ${CHROOT_X64}"
