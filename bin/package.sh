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
# Outbound proxy for ophub kernel fetches. Single-dash default: unset -> local
# socks5; explicitly empty (ALL_PROXY= from CI) -> stay empty = direct connect
# (CI has internet and can't reach that socks). Empty-safe below: proxy env/git
# config are only applied when non-empty.
: "${ALL_PROXY=socks5h://192.168.0.8:1180}"
: "${OPHUB_REPO:=https://github.com/ophub/amlogic-s9xxx-openwrt}"

# OUTDIR is the openwrt tree's parent (holds openwrt/bin/targets/...). Defaults to
# the local scratch tree; the CI workflow overrides it to $GITHUB_WORKSPACE (where
# it compiled) so this same script packages CI builds too — replacing the ophub
# GitHub action, which is a black box that re-clones ophub internally and so can't
# see our openwrt-install-amlogic patch. OPHUB_DIR stays under BUILD_ROOT.
: "${OUTDIR:=$BUILD_ROOT/build}"
OPHUB_DIR="$BUILD_ROOT/ophub"

# Image stamp (dotted date + _HHMMSS, no ':', git/filename-safe). The CI workflow
# overrides it with the ONE stamp minted in the setup job (needs.setup.outputs.
# build_stamp) so all three profiles' images — and the release tag derived from
# them — agree to the second. Locally there's no setup job, so mint it now
# (build/package time). Must be resolved ONCE here, not per-image in the loop
# below, or two N1 images in one run would disagree.
: "${BUILD_STAMP:=$(date '+%Y.%m.%d_%H%M%S')}"

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
# Only wire up the proxy when non-empty. CI passes ALL_PROXY= (direct); setting
# git http.proxy to an empty string would break clones there.
if [ -n "$ALL_PROXY" ]; then
    export ALL_PROXY HTTP_PROXY="$ALL_PROXY" HTTPS_PROXY="$ALL_PROXY"
    export http_proxy="$ALL_PROXY" https_proxy="$ALL_PROXY" all_proxy="$ALL_PROXY"
    git config --global http.proxy "$ALL_PROXY"
    git config --global https.proxy "$ALL_PROXY"
fi

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

# Stop ophub's installer from breaking AdGuardHome (root cause, verified on a real
# N1 flashed from a workflow image 2026-08-28). The 晶晨宝盒 "install to EMMC"
# script (openwrt-install-amlogic) does, while writing the emmc rootfs:
#     rm -rf usr/bin/AdGuardHome && ln -sf /mnt/${EMMC_NAME}p4/AdGuardHome usr/bin/
# i.e. it deletes the real 32 MB binary and symlinks /usr/bin/AdGuardHome at the
# p4 data partition — but never copies the binary into p4. Verified line-by-line
# (cwd is emmc p2 throughout): the installer first tar-copies the running usr/
# (incl. the real usr/bin/AdGuardHome) INTO emmc p2, then this line deletes it and
# links to p4, and the only other p4/AdGuardHome ref is a `mkdir -p .../data`
# (empty) — nothing ever puts the binary in p4. p4 is freshly formatted at
# install, so the link points at an empty dir → init.d execve's a directory →
# "Permission denied" crash loop, AGH never binds :53. (The neighbouring docker
# line is EQUALLY broken — same symlink to an empty p4 dir — and not a no-op
# either: its `ln -sf` still creates the symlink. It just never bites because we
# ship no dockerd, so nothing execve's /opt/docker. AGH is the one real casualty
# only because we DO ship AGH and its init.d execve's the symlink.) N1-only:
# x86/armvirt boot combined-efi directly and never run this installer. AGH's work_dir is
# /var/lib/adguardhome, not p4, so keeping the binary in /usr/bin is fully self-
# sufficient — we just neutralise the AGH line.
#
# CRITICAL — where the line lives, and why an earlier patch never fired: this
# script is NOT in the ophub repo. It ships in the luci-app-amlogic repo
# (root/usr/sbin/openwrt-install-amlogic), and remake pulls it in at RUN TIME —
# it clones luci-app-amlogic, `cp`s its root/usr/sbin/. into ${common_files}/
# usr/sbin (remake ~line 555, echo "luci-app-amlogic: sbin download completed"),
# then overlays common_files onto the rootfs (~line 913). So the file does NOT
# exist in the ophub clone at patch time. An earlier version of this patch tested
# `[ -f $OPHUB_DIR/make-openwrt/openwrt-files/common-files/usr/sbin/openwrt-
# install-amlogic ]` right after clone, found nothing (it's fetched later, by
# remake), and silently logged "upstream removed it" — so the patch NEVER applied,
# in CI or locally, and workflow images shipped the crash loop. (The old note
# about ophub commit 6bf6c75 "removing" the line was wrong: 6bf6c75 is an ophub
# commit, but the line lives in luci-app-amlogic, which still ships it on main.)
#
# Fix: patch remake itself (same technique as the losetup workaround above) to
# neutralise the AGH line right after remake copies luci-app-amlogic's sbin
# scripts into ${common_files}. The injected `sed` prefixes the line with
# `: #N1PATCH# ` (shell no-op + comment). The inner sed contains no backslashes so
# GNU sed's `a\` text doesn't mangle it (slashes are fine — they're literal inside
# `a\` text, not delimiters). After the sed, an injected grep re-checks that the
# marker actually landed; if the AGH line format drifts upstream so the sed misses,
# the grep prints a WARN instead of the patch silently no-op'ing (which would ship
# a crash-looping AGH). Idempotent via the #N1PATCH# marker in remake; re-applied
# every run since the reset/clone above restores pristine remake. WARN (not fail)
# if the anchor moves so packaging still runs.
agh_anchor='luci-app-amlogic: sbin download completed'
if grep -qF "$agh_anchor" "$OPHUB_DIR/remake"; then
    if ! grep -qF '#N1PATCH#' "$OPHUB_DIR/remake"; then
        sed -i '/luci-app-amlogic: sbin download completed/a\    sed -i "/AdGuardHome && ln -sf/s/^/: #N1PATCH# /" "${common_files}/usr/sbin/openwrt-install-amlogic" 2>/dev/null || true; grep -q "#N1PATCH#" "${common_files}/usr/sbin/openwrt-install-amlogic" 2>/dev/null || echo "WARN: #N1PATCH# AGH-line pattern drifted in openwrt-install-amlogic; AGH may crash-loop on emmc" >&2' "$OPHUB_DIR/remake"
    fi
else
    echo "WARN: ophub remake luci-app-amlogic sbin anchor not found; the AGH-on-" >&2
    echo "      emmc patch was NOT applied. If a flashed N1 shows AGH crash-" >&2
    echo "      looping (execve /usr/bin/AdGuardHome: Permission denied, symlink" >&2
    echo "      -> /mnt/mmcblk2p4/AdGuardHome), remake's luci-app-amlogic sbin" >&2
    echo "      copy step changed — re-check this patch's anchor." >&2
fi

# remake reads the rootfs from ./openwrt-armsr/ (armsr/armv8 target).
mkdir -p "$OPHUB_DIR/openwrt-armsr"
cp "$rootfs" "$OPHUB_DIR/openwrt-armsr/"

# Flags mirror the workflow: -b s905d -k 6.12.y -r ophub/kernel -u flippy
# -s 256/1024 -n mrabit. sudo strips the environment, so re-export the proxy
# explicitly — remake curls the flippy kernel and stalls without it. The proxy
# env vars are only injected when ALL_PROXY is non-empty (${ALL_PROXY:+...}); on
# CI (ALL_PROXY=) the whole prefix vanishes so remake connects direct, matching
# the guarded proxy block above (empty *_proxy would just mean "no proxy" anyway,
# but keep it consistent and clean).
( cd "$OPHUB_DIR" && sudo env \
    ${ALL_PROXY:+http_proxy="$ALL_PROXY" https_proxy="$ALL_PROXY" all_proxy="$ALL_PROXY"} \
    ${ALL_PROXY:+HTTP_PROXY="$ALL_PROXY" HTTPS_PROXY="$ALL_PROXY" ALL_PROXY="$ALL_PROXY"} \
    ./remake -b s905d -k 6.12.y -r ophub/kernel -u flippy -s 256/1024 -n mrabit )

# remake ran as root, so its out/ images are root-owned; move them to the
# repo's dist/ dir, renaming to the unified scheme shared with x86:
#   immortalwrt_<op>_<board>_k<kernel>_<date>_<time>.img.gz
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
    # Stamp = BUILD_STAMP (resolved once above): the CI setup job's shared value,
    # or a local mint. ophub only encodes a date, so the unified scheme's full
    # <date>_<time> always comes from here, never ophub's name.
    newname="immortalwrt_${op_version}_${bk}_${BUILD_STAMP}.img.gz"
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
