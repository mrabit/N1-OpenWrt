#!/usr/bin/env bash
# Repackage an existing bin/targets rootfs into a flashable N1 *.img.gz via ophub.
#
# Requires a prior build.sh run; this skips clone/feeds/compile entirely and just
# invokes the ophub remake step. Seconds to minutes, for iterating on the packaging
# step (ophub flags, loop workarounds, etc.) without recompiling.
#
# Usage:
#   bin/package.sh                              # repackage the last build
#   BUILD_ROOT=/mnt/ssd/owrt bin/package.sh     # different scratch volume
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Reuse derive_op_version() (and its BUILD_ROOT/REPO_BRANCH defaults). Sourcing
# the lib has no side effects beyond setting common tunable defaults + functions.
# shellcheck source=bin/build-lib.sh
source "$SCRIPT_DIR/build-lib.sh"

# --- tunables ----------------------------------------------------------------
# BUILD_ROOT / REPO_BRANCH defaults come from build-lib.sh. Package-only extras:
# Outbound proxy for ophub kernel fetches.
: "${ALL_PROXY:=socks5h://192.168.0.8:1180}"
: "${OPHUB_REPO:=https://github.com/ophub/amlogic-s9xxx-openwrt}"

OUTDIR="$BUILD_ROOT/build"
OPHUB_DIR="$BUILD_ROOT/ophub"

# --- sanity checks -----------------------------------------------------------
if [ ! -d "$OUTDIR/openwrt" ]; then
    echo "ERROR: no openwrt tree at $OUTDIR/openwrt; run bin/build.sh first." >&2
    exit 1
fi
if ! ls "$OUTDIR/openwrt/bin/targets/armsr/armv8/"*rootfs.tar.gz >/dev/null 2>&1; then
    echo "ERROR: no *rootfs.tar.gz under bin/targets; run bin/build.sh first." >&2
    exit 1
fi
if ! sudo -n true 2>/dev/null; then
    echo "ERROR: passwordless sudo required (loop mount + mkfs)." >&2
    exit 1
fi

# --- proxy -------------------------------------------------------------------
export ALL_PROXY HTTP_PROXY="$ALL_PROXY" HTTPS_PROXY="$ALL_PROXY"
export http_proxy="$ALL_PROXY" https_proxy="$ALL_PROXY" all_proxy="$ALL_PROXY"
git config --global http.proxy "$ALL_PROXY"
git config --global https.proxy "$ALL_PROXY"

echo "Repackaging N1 firmware"
echo "  rootfs:    $OUTDIR/openwrt/bin/targets/armsr/armv8/*rootfs.tar.gz"
echo "  output:    $REPO_ROOT/dist/"
echo "  proxy:     $ALL_PROXY"
echo

cd "$OUTDIR/openwrt"

rootfs="$(ls bin/targets/armsr/armv8/*rootfs.tar.gz 2>/dev/null | head -1)"
if [ -z "$rootfs" ]; then
    echo "ERROR: no *rootfs.tar.gz found." >&2
    exit 1
fi

# Clone/refresh ophub's packaging tree (main). Cached under BUILD_ROOT so the
# flippy kernel downloads it fetches are reused across runs.
if [ -d "$OPHUB_DIR/.git" ]; then
    git -C "$OPHUB_DIR" fetch --depth=1 origin main
    git -C "$OPHUB_DIR" reset --hard origin/main
else
    rm -rf "$OPHUB_DIR"
    git clone "$OPHUB_REPO" -b main --single-branch --depth=1 "$OPHUB_DIR"
fi

# Shared-kernel loop-partition workaround (OrbStack et al.). This host's loop
# driver is builtin with max_part=0, so `losetup -P` returns a device but
# never creates the p1/p2 partition nodes. ophub's remake then retries the
# bootfs mount 10x and dies ("[ 10 ] attempts to mount ... failed"). Force
# the nodes into existence with `partx` (an ioctl that works regardless of
# max_part) right after remake's losetup call. `partx -d` first clears any
# partial nodes; both are `|| true` so remake's `set -e` can't trip on them.
# After partx we poll until p1+p2 are block devices, then sleep 1s: partx
# creates the nodes synchronously, but a scanner (blkid/udev worker) can grab
# a freshly-created node for a moment, and the very next mkfs.vfat then fails
# on a busy device (its error is swallowed by remake's `>/dev/null 2>&1`,
# leaving p1 unformatted -> the later vfat mount 10x-fails). `udevadm settle`
# is a no-op without udevd, so the explicit wait+sleep is what closes the race.
# Re-applied every run because the reset/clone above restores pristine remake.
remake_anchor='loop_new="$(losetup -P -f --show'
if grep -qF "$remake_anchor" "$OPHUB_DIR/remake"; then
    if ! grep -qF 'partx -a "${loop_new}"' "$OPHUB_DIR/remake"; then
        sed -i '/loop_new="$(losetup -P -f --show/a\    partx -d "${loop_new}" 2>/dev/null || true; partx -a "${loop_new}" 2>/dev/null || true; udevadm settle 2>/dev/null || true; for _i in $(seq 1 50); do [ -b "${loop_new}p1" ] && [ -b "${loop_new}p2" ] && break; sleep 0.2; done; sleep 1' "$OPHUB_DIR/remake"
    fi
else
    echo "WARN: ophub remake losetup anchor not found; loop-partition workaround" >&2
    echo "      not applied. If packaging fails to mount /dev/loopNp1, remake's" >&2
    echo "      losetup logic changed — re-check this patch." >&2
fi

# remake reads the rootfs from ./openwrt-armsr/ (armsr/armv8 target).
mkdir -p "$OPHUB_DIR/openwrt-armsr"
cp "$rootfs" "$OPHUB_DIR/openwrt-armsr/"

# Flags mirror the workflow: -b s905d -k 6.12.y -r ophub/kernel -u flippy
# -s 256/1024 -n mrabit. sudo strips the environment, so re-export the proxy
# explicitly — remake curls the flippy kernel and stalls without it.
( cd "$OPHUB_DIR" && sudo env \
    http_proxy="$ALL_PROXY" https_proxy="$ALL_PROXY" all_proxy="$ALL_PROXY" \
    HTTP_PROXY="$ALL_PROXY" HTTPS_PROXY="$ALL_PROXY" ALL_PROXY="$ALL_PROXY" \
    ./remake -b s905d -k 6.12.y -r ophub/kernel -u flippy -s 256/1024 -n mrabit )

# remake ran as root, so its out/ images are root-owned; move them to the
# repo's dist/ dir, renaming to the unified scheme shared with x86:
#   immortalwrt_<op>_<board>_k<kernel>_<date>.img.gz
# The `s905d_k6.12.NN` segment is preserved verbatim from ophub's name because
# luci-app-amlogic OTA matches on `.*_s905d_.*k6.12.[0-9]+.*.img.gz` — renaming
# is safe as long as that segment and the .img.gz suffix survive. The date is
# reused from ophub's name (its packaging date) to stay consistent.
#
# Iterate ophub's out/ (N1 images only), NOT the whole dist/: dist/ may already
# hold an x86 image from a prior build, and the s905d parse below would fail on
# it and abort. Moving straight from out/ touches only what this run produced.
imgdest="$REPO_ROOT/dist"
mkdir -p "$imgdest"
# op version is read from the built tree's include/version.mk, falling back to
# REPO_BRANCH (openwrt-25.12 -> 25.12) if unreadable. See build-lib.sh.
op_version="$(derive_op_version "$OUTDIR/openwrt/include/version.mk")"
for src in "$OPHUB_DIR"/openwrt/out/*.img.gz; do
    base="$(basename "$src")"
    bk="$(echo "$base" | grep -oE 's905d_k[0-9]+\.[0-9]+\.[0-9]+' || true)"
    if [ -z "$bk" ]; then
        echo "ERROR: could not parse s905d_k<kernel> from ophub name '$base' —" >&2
        echo "       OTA needs it and the naming scheme requires it." >&2
        exit 1
    fi
    imgdate="$(echo "$base" | grep -oE '[0-9]{4}\.[0-9]{2}\.[0-9]{2}' | head -1 || true)"
    [ -z "$imgdate" ] && imgdate="$(date +%Y.%m.%d)"
    newname="immortalwrt_${op_version}_${bk}_${imgdate}.img.gz"
    # Recompress instead of mv: ophub's gzip stored the pre-rename name in the
    # FNAME header, so `gunzip -N`/GUI tools would decompress our renamed .gz to
    # the stale name. `gzip -n` writes no name/mtime, so extraction falls back to
    # stripping .gz and matches the shell (mirrors the workflow's Collect step).
    # src is root-owned (remake ran as root); sudo gzip -dc reads it, the pipe
    # writes the dist/ file as the build user. Drop the root-owned src after.
    # gzip -dc (not zcat: BSD zcat only groks .Z) for portability.
    sudo gzip -dc "$src" | gzip -n > "$imgdest/$newname"
    sudo rm -f "$src"
done
echo "Packaged firmware in $imgdest:"
ls -1 "$imgdest"/*.img.gz
