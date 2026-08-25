#!/usr/bin/env bash
# Single source of truth for the host apt packages needed to build the N1 image
# (the OpenWrt official Debian/Ubuntu dependency set).
#
# Run directly to install everything:
#   sudo ./bin/build-deps.sh
#
# Or source it to reuse the list without installing (bin/build.sh does this for
# its missing-package check). CI instead executes this script directly
# (.github/workflows/build.yml: `sudo -E bin/build-deps.sh`) to install everything.
#   source bin/build-deps.sh   # populates $BUILD_DEPS

BUILD_DEPS=(
    ack antlr3 asciidoc autoconf automake autopoint binutils bison
    build-essential bzip2 ccache clang cmake cpio curl device-tree-compiler
    ecj fastjar flex gawk gettext git libgnutls28-dev
    gperf haveged help2man intltool libelf-dev
    libglib2.0-dev libgmp3-dev libltdl-dev libmpc-dev libmpfr-dev
    libncurses-dev libpython3-dev libreadline-dev libssl-dev libtool
    libyaml-dev lld llvm lrzsz genisoimage msmtp nano ninja-build
    p7zip p7zip-full patch pkgconf python3 python3-docutils python3-pip
    python3-ply python3-pyelftools qemu-utils re2c rsync scons squashfs-tools
    subversion swig texinfo uglifyjs unzip upx-ucl vim wget xmlto xxd
    zlib1g-dev zstd
    # ophub `remake` packaging (bin/package.sh): partitioning + making
    # the N1 btrfs root and boot FAT filesystems. Unused by the pure `make` build.
    btrfs-progs dosfstools parted uuid-runtime
)

# 32-bit multilib / i386 packages only exist (and are only needed) on x86 hosts.
# On arm64 and other arches they are unavailable, so add them only on amd64/i386.
case "$(dpkg --print-architecture 2>/dev/null)" in
    amd64|i386)
        BUILD_DEPS+=(g++-multilib gcc-multilib lib32gcc-s1 libc6-dev-i386)
        ;;
esac

# When executed (not sourced), install the packages.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    SUDO=""
    [ "$(id -u)" -ne 0 ] && SUDO="sudo"
    # Keep apt fully non-interactive (e.g. msmtp's AppArmor debconf prompt would
    # otherwise block the install waiting for a keypress). Pass the var inline so
    # it survives sudo's env stripping and also works when already root.
    echo "Installing ${#BUILD_DEPS[@]} build dependencies via apt-get..."
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${BUILD_DEPS[@]}"
    echo "Done."
fi
