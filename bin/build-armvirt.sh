#!/usr/bin/env bash
# Native build for the ARM64 VM image (no Docker). Invoked via `bin/build.sh armvirt`
# or directly.
#
# Clones ImmortalWrt, runs the shared diy.sh, applies the shared overlay + armvirt
# config (+ common/config.services) and compiles. Like x86 (and unlike N1) there
# is NO ophub repackaging: OpenWrt's armsr/armv8 target already emits a bootable
# *-generic-squashfs-combined-efi.img.gz (ARM SystemReady / UEFI), which boots
# directly under UTM/QEMU on Apple Silicon and any EDK2 aarch64 hypervisor. It's
# published after renaming to the unified scheme shared with N1/x86
# (immortalwrt_<op>_armv8_k<kernel>_<date>). "armvirt" is the ARM-community name for
# an ARM virtual-machine image (an OpenWrt legacy target name); the image's board
# segment stays `armv8` (the arch), matching N1's `s905d` / x86's `x86_64`.
#
# The openwrt tree and all caches live under BUILD_ROOT, which MUST be on a native
# ext4/xfs/btrfs volume (OpenWrt's parallel small-file writes corrupt on virtiofs).
#
# All common machinery lives in bin/build-lib.sh; this wrapper only sets the
# armvirt-specific bits and drives the order.
#
# Usage:
#   bin/build.sh armvirt
#   BUILD_ROOT=/mnt/ssd/owrt bin/build.sh armvirt
#   ALL_PROXY=socks5h://host:port bin/build.sh armvirt
#   JOBS=4 bin/build.sh armvirt
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON_DIR="$REPO_ROOT/common"
PROFILE_DIR="$REPO_ROOT/armsr/armv8/armvirt"
PROFILE_NAME="armvirt"
GO_REQUIRED=1   # aarch64 target: on a local arm64 host Go can't build from source,
                # so the external bootstrap is required (same as N1). In CI the
                # x86_64 runner cross-compiles and builds Go from source, so the
                # workflow needs no bootstrap.

# shellcheck source=bin/build-lib.sh
source "$SCRIPT_DIR/build-lib.sh"

# armvirt uses its own scratch subtree + feeds/ccache so N1/x86/armvirt builds can
# coexist under one BUILD_ROOT. It shares armsr/armv8 as the OpenWrt target with
# N1, so a separate OUTDIR is essential (same bin/targets subdir otherwise). dl/
# is shared (same downloads) via the lib's DL_CACHE.
OUTDIR="$BUILD_ROOT/build-armvirt"
FEEDS_CACHE="$BUILD_ROOT/cache/feeds-armvirt"
CCACHE_DIR="$BUILD_ROOT/cache/ccache-armvirt"
LOG="$BUILD_ROOT/build-armvirt.log"

# Full-build diy hook: armvirt uses the shared diy.sh directly (no amlogic clone).
run_diy() { COMMON_DIR="$COMMON_DIR" bash "$COMMON_DIR/diy.sh"; }

# --- sanity checks -----------------------------------------------------------
check_buildroot_fs
check_go_bootstrap
check_disk
ensure_deps
setup_proxy

echo "Building ARM64 VM (armvirt) image natively"
echo "  repo:      $REPO_ROOT"
echo "  build dir: $OUTDIR  (fstype=$fstype)"
echo "  artifacts: $ARTIFACT_DIR/bin/targets"
echo "  proxy:     $ALL_PROXY"
echo "  jobs:      $JOBS"
echo "  log:       $LOG"
echo

# Everything below is teed to the log.
{
do_build
publish_artifacts

# Drop the bootable image into the repo's dist/ dir, alongside N1/x86. dist/ is
# git-ignored. We publish only the SQUASHFS combined-efi (read-only root +
# overlay, sysupgrade-friendly) — the build also emits an ext4 variant but the
# squashfs image is the standard router choice.
dest="$ARTIFACT_DIR/bin/targets"
imgdest="$REPO_ROOT/dist"
mkdir -p "$imgdest"
src="$(find "$dest" -name '*squashfs-combined-efi.img.gz' -print -quit)"
if [ -n "$src" ]; then
    # Rename to the unified scheme shared with N1/x86:
    #   immortalwrt_<op>_armv8_k<kernel>_<date>.img.gz
    # The kernel version comes from the target manifest (ImmortalWrt's own build);
    # the date is generated locally (TZ from the environment). No OTA naming
    # constraint here, so this is purely cosmetic alignment.
    op_version="$(derive_op_version "$OUTDIR/openwrt/include/version.mk")"
    kver="$(grep -E '^kernel ' "$dest"/armsr/armv8/*.manifest 2>/dev/null \
        | awk '{print $3}' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    if [ -z "$kver" ]; then
        echo "ERROR: could not parse kernel from $dest/armsr/armv8/*.manifest — the" >&2
        echo "       naming scheme requires it. Manifest kernel line:" >&2
        grep -E '^kernel ' "$dest"/armsr/armv8/*.manifest >&2 || echo "  (no ^kernel line)" >&2
        exit 1
    fi
    imgdate="$(date +%Y.%m.%d)"
    newname="immortalwrt_${op_version}_armv8_k${kver}_${imgdate}.img.gz"
    cp -f "$src" "$imgdest/$newname"
    echo "Flashable EFI image copied to $imgdest:"
    ls -1 "$imgdest/$newname"
else
    echo "WARN: no *squashfs-combined-efi.img.gz found under $dest — check the" >&2
    echo "      armvirt .config GRUB/rootfs symbols (make defconfig may have flipped" >&2
    echo "      them, or CONFIG_TARGET_ROOTFS_SQUASHFS got disabled)." >&2
fi

print_build_time
} 2>&1 | tee "$LOG"
