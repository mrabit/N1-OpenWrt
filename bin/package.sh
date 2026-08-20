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

# --- tunables ----------------------------------------------------------------
: "${BUILD_ROOT:=/opt/openwrt-build}"
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
# Re-applied every run because the reset/clone above restores pristine remake.
remake_anchor='loop_new="$(losetup -P -f --show'
if grep -qF "$remake_anchor" "$OPHUB_DIR/remake"; then
    if ! grep -qF 'partx -a "${loop_new}"' "$OPHUB_DIR/remake"; then
        sed -i '/loop_new="$(losetup -P -f --show/a\    partx -d "${loop_new}" 2>/dev/null || true; partx -a "${loop_new}" 2>/dev/null || true; udevadm settle 2>/dev/null || true' "$OPHUB_DIR/remake"
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
# repo's dist/ dir and reclaim ownership.
imgdest="$REPO_ROOT/dist"
mkdir -p "$imgdest"
sudo mv "$OPHUB_DIR"/openwrt/out/*.img.gz "$imgdest/"
sudo chown "$(id -u):$(id -g)" "$imgdest"/*.img.gz
echo "Packaged firmware moved to $imgdest"
ls -1 "$imgdest"/*.img.gz
