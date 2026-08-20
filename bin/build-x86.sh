#!/usr/bin/env bash
# Native build for the x86/64 image (no Docker). Invoked via `bin/build.sh x86`
# or directly.
#
# Clones ImmortalWrt, runs the shared diy.sh, applies the shared overlay + x86
# config (+ common/config.services) and compiles. Unlike N1 there is NO ophub
# repackaging: OpenWrt's x86 target already emits a bootable
# *-generic-squashfs-combined-efi.img.gz, which is published directly.
#
# The openwrt tree and all caches live under BUILD_ROOT, which MUST be on a native
# ext4/xfs/btrfs volume (OpenWrt's parallel small-file writes corrupt on virtiofs).
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

# --- tunables ----------------------------------------------------------------
: "${REPO_BRANCH:=openwrt-25.12}"
: "${REPO_URL:=https://github.com/immortalwrt/immortalwrt}"
: "${BUILD_ROOT:=/opt/openwrt-build}"
# Optional external Go bootstrap. Unlike arm64, x86_64 can build Go from source,
# so this is not required; if set and present it is used, otherwise left to make.
: "${GO_BOOTSTRAP:=/usr/local/go-bootstrap}"
: "${ALL_PROXY:=socks5h://192.168.0.8:1180}"
: "${JOBS:=$(nproc)}"
: "${ARTIFACT_DIR:=$BUILD_ROOT/output}"
# INCREMENTAL=1 reuses a warm tree (skips clone/feeds/diy.sh); see build-N1.sh.
: "${INCREMENTAL:=0}"

# x86 uses its own scratch subtree so an N1 build and an x86 build can coexist
# under the same BUILD_ROOT without clobbering each other's openwrt tree.
OUTDIR="$BUILD_ROOT/build-x86"
DL_CACHE="$BUILD_ROOT/cache/dl"
FEEDS_CACHE="$BUILD_ROOT/cache/feeds-x86"
CCACHE_DIR="$BUILD_ROOT/cache/ccache-x86"
LOG="$BUILD_ROOT/build-x86.log"

# --- sanity checks -----------------------------------------------------------
mkdir -p "$BUILD_ROOT"
fstype="$(stat -f -c '%T' "$BUILD_ROOT")"
case "$fstype" in
    virtiofs|fuseblk|nfs|cifs|9p)
        echo "ERROR: BUILD_ROOT=$BUILD_ROOT is on '$fstype', which corrupts" >&2
        echo "       OpenWrt's parallel small-file writes. Point BUILD_ROOT at" >&2
        echo "       a native ext4/xfs/btrfs volume." >&2
        exit 1
        ;;
esac

avail_kb="$(df -Pk "$BUILD_ROOT" | awk 'NR==2{print $4}')"
if [ "$avail_kb" -lt $((20 * 1024 * 1024)) ]; then
    echo "WARN: only $((avail_kb / 1024 / 1024))G free on $BUILD_ROOT; a full" >&2
    echo "      build may need 20-30G. Continuing anyway." >&2
fi

# Install any missing apt dependencies up front via build-deps.sh (handles sudo +
# non-interactive apt itself). The ophub packaging tools it also lists are unused
# on x86 but harmless.
DEPS_SCRIPT="$SCRIPT_DIR/build-deps.sh"
if command -v dpkg-query >/dev/null 2>&1 && [ -f "$DEPS_SCRIPT" ]; then
    # shellcheck source=/dev/null
    source "$DEPS_SCRIPT"   # sourcing only populates BUILD_DEPS; it does not install
    missing=""
    for pkg in "${BUILD_DEPS[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" \
            || missing="$missing $pkg"
    done
    if [ -n "$missing" ]; then
        echo "Missing apt packages:$missing"
        echo "Installing via $DEPS_SCRIPT ..."
        "$DEPS_SCRIPT"
    fi
fi

# --- proxy -------------------------------------------------------------------
export ALL_PROXY HTTP_PROXY="$ALL_PROXY" HTTPS_PROXY="$ALL_PROXY"
export http_proxy="$ALL_PROXY" https_proxy="$ALL_PROXY" all_proxy="$ALL_PROXY"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
export FORCE_UNSAFE_CONFIGURE=1
git config --global http.proxy "$ALL_PROXY"
git config --global https.proxy "$ALL_PROXY"

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
mkdir -p "$OUTDIR" "$ARTIFACT_DIR" "$DL_CACHE" "$FEEDS_CACHE" "$CCACHE_DIR"

update_feeds() {
    for attempt in 1 2 3; do
        ./scripts/feeds update -a && return 0
        echo "Feed update failed (attempt $attempt/3), retrying..." >&2
        sleep $((attempt * 5))
    done
    echo "Feed update failed after 3 attempts." >&2
    return 1
}

# Re-stamp shared overlay + x86 .config (+ common services) and regenerate
# defconfig. Idempotent; run on both full and incremental paths.
apply_overlay() {
    rm -rf files .config
    cp -r "$COMMON_DIR/files" ./files
    [ -d "$PROFILE_DIR/files" ] && cp -rf "$PROFILE_DIR/files/." ./files/
    cp "$PROFILE_DIR/.config" ./.config
    cat "$COMMON_DIR/config.services" >> .config

    export CCACHE_DIR
    cat >> .config <<'EOF'
CONFIG_CCACHE=y
EOF
    make defconfig

    # Use a prebuilt Go as external bootstrap if one is present (optional on x86).
    if [ -x "$GO_BOOTSTRAP/bin/go" ]; then
        cat >> .config <<EOF
CONFIG_GOLANG_BUILD_BOOTSTRAP=n
CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT="$GO_BOOTSTRAP"
EOF
        make defconfig
    fi
}

if [ "$INCREMENTAL" = "1" ] && [ -f "$OUTDIR/openwrt/.config" ]; then
    echo "INCREMENTAL=1: reusing warm tree at $OUTDIR/openwrt (skipping clone/feeds/diy.sh)."
    cd "$OUTDIR/openwrt"
    [ -L dl ] || { rm -rf dl; ln -s "$DL_CACHE" dl; }
    [ -L feeds ] || { rm -rf feeds; ln -s "$FEEDS_CACHE" feeds; }
    apply_overlay
    make download -j"$(( JOBS * 2 ))"
    find dl/ -size -1k -exec rm -f {} \;
    make -j"$(( JOBS + 1 ))" || make -j1 V=s
else
    [ "$INCREMENTAL" = "1" ] && echo "INCREMENTAL=1 but no warm tree found; doing a full build."
    rm -rf "$OUTDIR/openwrt"
    git clone "$REPO_URL" -b "$REPO_BRANCH" --single-branch --depth=1 "$OUTDIR/openwrt"
    cd "$OUTDIR/openwrt"

    rm -rf dl feeds
    ln -s "$DL_CACHE" dl
    ln -s "$FEEDS_CACHE" feeds

    for repo in "$FEEDS_CACHE"/*/.git; do
        [ -d "$repo" ] || continue
        dir="${repo%/.git}"
        echo "Resetting cached feed: $(basename "$dir")"
        git -C "$dir" reset --hard >/dev/null 2>&1 || true
        git -C "$dir" clean -fdx >/dev/null 2>&1 || true
    done

    update_feeds
    COMMON_DIR="$COMMON_DIR" bash "$COMMON_DIR/diy.sh"
    update_feeds
    ./scripts/feeds install -a

    apply_overlay

    make download -j"$(( JOBS * 2 ))"
    find dl/ -size -1k -exec rm -f {} \;
    make -j"$(( JOBS + 1 ))" || make -j1 V=s
fi

# Publish firmware. x86 emits a bootable combined image directly — no ophub step.
if [ -d bin/targets ]; then
    dest="$ARTIFACT_DIR/bin/targets"
    rm -rf "$dest"
    mkdir -p "$dest"
    cp -a bin/targets/. "$dest/"
    echo "Firmware images copied to $dest"

    # Also drop the bootable image into the repo's dist/ dir, so both profiles
    # land their final flashable image in the same place (N1 via ophub in
    # package.sh, x86 here). dist/ is git-ignored. We publish only the SQUASHFS
    # combined-efi (read-only root + overlay, sysupgrade-friendly) — the build
    # also emits an ext4 variant (read-write root) but the squashfs image is the
    # standard router choice, so it's the one that ships.
    imgdest="$REPO_ROOT/dist"
    mkdir -p "$imgdest"
    if find "$dest" -name '*squashfs-combined-efi.img.gz' -print -quit | grep -q .; then
        find "$dest" -name '*squashfs-combined-efi.img.gz' -exec cp -f {} "$imgdest/" \;
        echo "Flashable EFI image(s) copied to $imgdest:"
        ls -1 "$imgdest"/*squashfs-combined-efi.img.gz
    else
        echo "WARN: no *squashfs-combined-efi.img.gz found under $dest — check the" >&2
        echo "      x86 .config GRUB/rootfs symbols (make defconfig may have flipped" >&2
        echo "      them, or CONFIG_TARGET_ROOTFS_SQUASHFS got disabled)." >&2
    fi
else
    echo "No bin/targets directory found; build may have failed." >&2
    exit 1
fi

printf 'Total build time: %02dh %02dm %02ds\n' \
    $((SECONDS / 3600)) $(((SECONDS % 3600) / 60)) $((SECONDS % 60))
} 2>&1 | tee "$LOG"
