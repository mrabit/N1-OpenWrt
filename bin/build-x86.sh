#!/usr/bin/env bash
# Native build for the x86/64 image (no Docker). Invoked via `bin/build.sh x86`
# or directly.
#
# Clones ImmortalWrt, runs the shared diy.sh, applies the shared overlay + x86
# config (+ common/config.services) and compiles. Unlike N1 there is NO ophub
# repackaging: OpenWrt's x86 target already emits a bootable
# *-generic-squashfs-combined-efi.img.gz, which is published after renaming to
# the unified scheme shared with N1 (immortalwrt_<op>_x86_64_k<kernel>_<date>).
#
# The openwrt tree and all caches live under BUILD_ROOT, which MUST be on a native
# ext4/xfs/btrfs volume (OpenWrt's parallel small-file writes corrupt on virtiofs).
#
# All common machinery lives in bin/build-lib.sh; this wrapper only sets the
# x86-specific bits and drives the order.
#
# Usage:
#   bin/build.sh x86
#   BUILD_ROOT=/mnt/ssd/owrt bin/build.sh x86
#   ALL_PROXY=socks5h://host:port bin/build.sh x86
#   JOBS=4 bin/build.sh x86
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON_DIR="$REPO_ROOT/common"
PROFILE_DIR="$REPO_ROOT/x86/64"
PROFILE_NAME="x86"
GO_REQUIRED=0   # x86_64 can build Go from source; the external bootstrap is optional

# shellcheck source=bin/build-lib.sh
source "$SCRIPT_DIR/build-lib.sh"

# x86 uses its own scratch subtree + feeds/ccache so an N1 build and an x86 build
# can coexist under the same BUILD_ROOT without clobbering each other. dl/ is
# shared (same downloads) via the lib's DL_CACHE.
OUTDIR="$BUILD_ROOT/build-x86"
FEEDS_CACHE="$BUILD_ROOT/cache/feeds-x86"
CCACHE_DIR="$BUILD_ROOT/cache/ccache-x86"
LOG="$BUILD_ROOT/build-x86.log"

# Full-build diy hook: x86 uses the shared diy.sh directly (no amlogic clone).
run_diy() { COMMON_DIR="$COMMON_DIR" bash "$COMMON_DIR/diy.sh"; }

# --- sanity checks -----------------------------------------------------------
check_buildroot_fs
check_disk
ensure_deps
setup_proxy

echo "Building x86/64 image natively"
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

# Also drop the bootable image into the repo's dist/ dir, so both profiles land
# their final flashable image in the same place (N1 via ophub in package.sh, x86
# here). dist/ is git-ignored. We publish only the SQUASHFS combined-efi
# (read-only root + overlay, sysupgrade-friendly) — the build also emits an ext4
# variant (read-write root) but the squashfs image is the standard router choice.
dest="$ARTIFACT_DIR/bin/targets"
imgdest="$REPO_ROOT/dist"
mkdir -p "$imgdest"
src="$(find "$dest" -name '*squashfs-combined-efi.img.gz' -print -quit)"
if [ -n "$src" ]; then
    # Rename to the unified scheme shared with N1:
    #   immortalwrt_<op>_x86_64_k<kernel>_<date>.img.gz
    # The kernel version comes from the target manifest (e.g. 6.12.103); the date
    # is generated locally (TZ from the environment). x86 has no OTA naming
    # constraint, so this is purely cosmetic alignment with N1.
    op_version="$(derive_op_version "$OUTDIR/openwrt/include/version.mk")"
    kver="$(grep -E '^kernel ' "$dest"/x86/64/*.manifest 2>/dev/null \
        | awk '{print $3}' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    if [ -z "$kver" ]; then
        echo "ERROR: could not parse kernel from $dest/x86/64/*.manifest — the" >&2
        echo "       naming scheme requires it. Manifest kernel line:" >&2
        grep -E '^kernel ' "$dest"/x86/64/*.manifest >&2 || echo "  (no ^kernel line)" >&2
        exit 1
    fi
    imgdate="$(date +%Y.%m.%d)"
    newname="immortalwrt_${op_version}_x86_64_k${kver}_${imgdate}.img.gz"
    cp -f "$src" "$imgdest/$newname"
    echo "Flashable EFI image copied to $imgdest:"
    ls -1 "$imgdest/$newname"
else
    echo "WARN: no *squashfs-combined-efi.img.gz found under $dest — check the" >&2
    echo "      x86 .config GRUB/rootfs symbols (make defconfig may have flipped" >&2
    echo "      them, or CONFIG_TARGET_ROOTFS_SQUASHFS got disabled)." >&2
fi

print_build_time
} 2>&1 | tee "$LOG"
