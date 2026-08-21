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
# All common machinery lives in bin/build-lib.sh; this wrapper only sets the
# N1-specific bits and drives the order. Tunables (BUILD_ROOT, ARTIFACT_DIR,
# GO_BOOTSTRAP, ALL_PROXY, JOBS, REPO_BRANCH, OPHUB_REPO, INCREMENTAL) come from
# the environment.
#
# Usage:
#   bin/build.sh N1                            # foreground, logs to $BUILD_ROOT/build.log
#   BUILD_ROOT=/mnt/ssd/owrt bin/build.sh N1   # different native scratch volume
#   ALL_PROXY=socks5h://host:port bin/build.sh N1
#   JOBS=4 bin/build.sh N1                     # cap compile parallelism
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON_DIR="$REPO_ROOT/common"
PROFILE_DIR="$REPO_ROOT/armsr/armv8/N1"
PROFILE_NAME="N1"
GO_REQUIRED=1   # arm64 can't build Go from source; the external bootstrap is required

# shellcheck source=bin/build-lib.sh
source "$SCRIPT_DIR/build-lib.sh"

# N1 scratch subtree + caches (dl/ is shared via the lib's DL_CACHE).
OUTDIR="$BUILD_ROOT/build"
FEEDS_CACHE="$BUILD_ROOT/cache/feeds"
CCACHE_DIR="$BUILD_ROOT/cache/ccache"
LOG="$BUILD_ROOT/build.log"

# Full-build diy hook: N1's diy.sh applies the shared steps then clones luci-app-amlogic.
run_diy() { bash "$PROFILE_DIR/diy.sh"; }

# --- sanity checks -----------------------------------------------------------
check_buildroot_fs
check_go_bootstrap
check_disk
ensure_deps
setup_proxy

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
do_build
publish_artifacts

# Package the rootfs.tar.gz into a flashable N1 *.img.gz via ophub. The packaging
# step lives in bin/package.sh so it can also be run standalone against a prior
# build; the script re-resolves BUILD_ROOT/ALL_PROXY/OPHUB_REPO from the env and
# works off the tree at $OUTDIR/openwrt (a cwd-independent absolute path). Pass
# REPO_BRANCH explicitly so the op version in the image name (derived from it)
# always matches the branch this build actually compiled.
REPO_BRANCH="$REPO_BRANCH" "$SCRIPT_DIR/package.sh"

print_build_time
} 2>&1 | tee "$LOG"
