#!/usr/bin/env bash
# Native build for the N1 (Amlogic S905D) image (no Docker). Invoked via
# bin/build.sh (default profile) or directly.
#
# Clones ImmortalWrt, runs the N1 diy.sh, applies the shared overlay + N1 config
# (+ common/config.services) and compiles, then packages the rootfs.tar.gz into a
# flashable *.img.gz via ophub. Publishes firmware to $ARTIFACT_DIR/bin/targets
# (default BUILD_ROOT/output; set ARTIFACT_DIR=./output to pull it into the repo).
#
# The openwrt tree and all caches live under BUILD_ROOT, which MUST be on a native
# ext4/xfs/btrfs volume: OpenWrt's tree has huge numbers of small parallel writes
# and hardlinks that corrupt on a virtiofs/macOS bind mount. Keep the repo where
# it is; only BUILD_ROOT must be native.
#
# Usage:
#   bin/build.sh N1                           # foreground, logs to $BUILD_ROOT/build.log
#   BUILD_ROOT=/mnt/ssd/owrt bin/build.sh N1   # different native scratch volume
#   ALL_PROXY=socks5h://host:port bin/build.sh N1
#   JOBS=4 bin/build.sh N1                     # cap compile parallelism
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON_DIR="$REPO_ROOT/common"
PROFILE_DIR="$REPO_ROOT/armsr/armv8/N1"

# --- tunables ----------------------------------------------------------------
: "${REPO_BRANCH:=openwrt-25.12}"
: "${REPO_URL:=https://github.com/immortalwrt/immortalwrt}"
# Native scratch area for the throwaway openwrt tree + persistent caches.
: "${BUILD_ROOT:=/opt/openwrt-build}"
# Prebuilt Go used as external bootstrap (Go >=1.26 needs bootstrap >=1.24.6;
# on arm64 the source bootstrap from go1.4 is unsupported).
: "${GO_BOOTSTRAP:=/usr/local/go-bootstrap}"
# Outbound proxy; go.dev / some feeds are unreachable directly here.
# socks5h keeps DNS resolution on the proxy side.
: "${ALL_PROXY:=socks5h://192.168.0.8:1180}"
: "${JOBS:=$(nproc)}"
# Where the finished firmware is copied. Defaults to the native scratch volume
# to keep the repo (often a slow virtiofs mount) clean; override to taste.
: "${ARTIFACT_DIR:=$BUILD_ROOT/output}"
: "${OPHUB_REPO:=https://github.com/ophub/amlogic-s9xxx-openwrt}"
# Fast path for local iteration; default off (full clean build otherwise).
#   INCREMENTAL=1  reuse a warm openwrt tree: skip clone/feeds/diy.sh and let make
#                  rebuild only what changed. Re-applies the overlay/.config each
#                  run, so package/overlay edits ARE picked up; diy.sh edits are
#                  NOT (those patch pristine source — run a full build). A
#                  toolchain/kernel .config change may still need a full rebuild.
: "${INCREMENTAL:=0}"

OUTDIR="$BUILD_ROOT/build"
DL_CACHE="$BUILD_ROOT/cache/dl"
FEEDS_CACHE="$BUILD_ROOT/cache/feeds"
CCACHE_DIR="$BUILD_ROOT/cache/ccache"
LOG="$BUILD_ROOT/build.log"

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
if [ ! -x "$GO_BOOTSTRAP/bin/go" ]; then
    echo "ERROR: Go bootstrap not found at $GO_BOOTSTRAP/bin/go." >&2
    echo "       Install a prebuilt Go there, e.g.:" >&2
    echo "         arch=\$(dpkg --print-architecture)" >&2
    echo "         curl -fsSL --proxy \"$ALL_PROXY\" \\" >&2
    echo "           https://go.dev/dl/go1.24.9.linux-\${arch}.tar.gz | \\" >&2
    echo "           sudo tar -C /usr/local -xzf - && \\" >&2
    echo "         sudo mv /usr/local/go $GO_BOOTSTRAP" >&2
    exit 1
fi

avail_kb="$(df -Pk "$BUILD_ROOT" | awk 'NR==2{print $4}')"
if [ "$avail_kb" -lt $((20 * 1024 * 1024)) ]; then
    echo "WARN: only $((avail_kb / 1024 / 1024))G free on $BUILD_ROOT; a full" >&2
    echo "      build may need 20-30G. Continuing anyway." >&2
fi

# Install any missing apt dependencies up front via build-deps.sh (it handles
# sudo and non-interactive apt itself), rather than only warning. The list in
# build-deps.sh already covers the ophub packaging tools (btrfs-progs, etc.), so
# doing this before the compile also guarantees remake's tools are present.
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
# Route all outbound fetches (curl/wget, rust/go bootstrap, feeds) through the
# proxy. git does not honour ALL_PROXY for socks, so wire http.proxy explicitly.
export ALL_PROXY HTTP_PROXY="$ALL_PROXY" HTTPS_PROXY="$ALL_PROXY"
export http_proxy="$ALL_PROXY" https_proxy="$ALL_PROXY" all_proxy="$ALL_PROXY"
export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
export FORCE_UNSAFE_CONFIGURE=1
git config --global http.proxy "$ALL_PROXY"
git config --global https.proxy "$ALL_PROXY"

echo "Building N1 image natively"
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

# Re-stamp the shared overlay + N1 .config (+ common services) onto the tree and
# regenerate defconfig. Cheap and idempotent, so both full and incremental paths
# run it — an incremental build thus picks up package/overlay edits without
# touching feeds or diy.sh.
apply_overlay() {
    rm -rf files .config
    cp -r "$COMMON_DIR/files" ./files
    # Profile-specific overlay files (if any) layer on top of the shared set.
    [ -d "$PROFILE_DIR/files" ] && cp -rf "$PROFILE_DIR/files/." ./files/
    cp "$PROFILE_DIR/.config" ./.config
    cat "$COMMON_DIR/config.services" >> .config

    # ccache: reuse cached object files across recompiles.
    export CCACHE_DIR
    cat >> .config <<'EOF'
CONFIG_CCACHE=y
EOF
    make defconfig

    # Use the prebuilt Go as an external bootstrap instead of building one from
    # source (unsupported on arm64).
    cat >> .config <<EOF
CONFIG_GOLANG_BUILD_BOOTSTRAP=n
CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT="$GO_BOOTSTRAP"
EOF
    make defconfig
}

# Incremental reuse of a warm tree needs .config present (proof a prior full
# build got past setup). Fall back to a full build otherwise.
if [ "$INCREMENTAL" = "1" ] && [ -f "$OUTDIR/openwrt/.config" ]; then
    echo "INCREMENTAL=1: reusing warm tree at $OUTDIR/openwrt (skipping clone/feeds/diy.sh)."
    cd "$OUTDIR/openwrt"
    # Re-point dl/ and feeds/ at the caches in case they went stale.
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

    # Point the fresh tree's dl/ and feeds/ at the persistent caches. The clone
    # ships neither directory, so a plain symlink is safe.
    rm -rf dl feeds
    ln -s "$DL_CACHE" dl
    ln -s "$FEEDS_CACHE" feeds

    # diy.sh mutates feed contents (edits Makefiles). On a warm feeds cache those
    # edits persist and break incremental `feeds update`; reset to pristine first.
    for repo in "$FEEDS_CACHE"/*/.git; do
        [ -d "$repo" ] || continue
        dir="${repo%/.git}"
        echo "Resetting cached feed: $(basename "$dir")"
        git -C "$dir" reset --hard >/dev/null 2>&1 || true
        git -C "$dir" clean -fdx >/dev/null 2>&1 || true
    done

    update_feeds
    bash "$PROFILE_DIR/diy.sh"
    update_feeds
    ./scripts/feeds install -a

    apply_overlay

    make download -j"$(( JOBS * 2 ))"
    # dl/ is a symlink to the cache; the trailing slash makes find descend into it.
    find dl/ -size -1k -exec rm -f {} \;
    make -j"$(( JOBS + 1 ))" || make -j1 V=s
fi

# Publish firmware to the repo's output/ dir.
if [ -d bin/targets ]; then
    dest="$ARTIFACT_DIR/bin/targets"
    rm -rf "$dest"
    mkdir -p "$dest"
    cp -a bin/targets/. "$dest/"
    echo "Firmware images copied to $dest"
else
    echo "No bin/targets directory found; build may have failed." >&2
    exit 1
fi

# Package the rootfs.tar.gz into a flashable N1 *.img.gz via ophub. The packaging
# step lives in bin/package.sh so it can also be run standalone against a prior
# build; the script re-resolves BUILD_ROOT/ALL_PROXY/OPHUB_REPO from the env and
# works off the tree at $OUTDIR/openwrt, which is the cwd-independent absolute path.
# Pass REPO_BRANCH explicitly so the op version in the image name (derived from it)
# always matches the branch this build actually compiled.
REPO_BRANCH="$REPO_BRANCH" "$SCRIPT_DIR/package.sh"

# Total wall-clock time. SECONDS is a bash builtin counting since the script
# started, so it spans clone + feeds + compile + packaging.
printf 'Total build time: %02dh %02dm %02ds\n' \
    $((SECONDS / 3600)) $(((SECONDS % 3600) / 60)) $((SECONDS % 60))
} 2>&1 | tee "$LOG"
