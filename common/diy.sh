#!/bin/bash
# Shared feed/source customization for every profile (N1, x86, ...).
#
# Runs from the openwrt tree root, after `feeds update -a`. Applies the arch-
# agnostic patches and feed edits. Profile-specific diy scripts (e.g.
# armsr/armv8/N1/diy.sh) source this first, then add their own steps.
#
# Fail loudly on any error. Without this the script's exit code is that of its
# last command (the FMSH rm loop, always 0), so a failed luci.patch / EasyTier
# clone / cp would be silently swallowed — and it also masked failures from the
# N1 wrapper's own `set -e` (it sources this via `bash`, seeing only the 0 exit).
set -e

# COMMON_DIR is exported by the caller (build lib / workflow) and points at this
# file's directory; fall back to it when run standalone.
: "${COMMON_DIR:=$(cd "$(dirname "$0")" && pwd)}"

# Adjust source code: online-users LuCI fix (device-name aware /proc/net/arp parse).
# Deliberately NOT fatal under set -e: this is a cosmetic LuCI fix (online-users
# display only), and `patch -N` returns non-zero both on real drift AND when the
# hunk is already applied — including the benign case where upstream luci fixes
# the arp parse itself, which must NOT abort the whole build. So wrap in `if`
# (a failing condition doesn't trip set -e): apply forward on a pristine tree,
# else WARN and carry on. Contrast the EasyTier clone/cp below, which stays fatal.
if patch -p1 -N -f < "$COMMON_DIR/luci.patch" >/dev/null 2>&1; then
	: # applied (or forward-applied) cleanly
else
	echo "WARN: luci.patch did not apply (already fixed upstream, or drifted) — online-users LuCI fix skipped." >&2
fi

# Drop attendedsysupgrade from the default luci collection (unused, pulls extra deps).
sed -i '/luci-app-attendedsysupgrade/d' feeds/luci/collections/luci/Makefile

# EasyTier (decentralized mesh VPN) — not in ImmortalWrt feeds, pull from upstream.
# The `easytier` core Makefile downloads a prebuilt release binary at build time
# (Build/Prepare wget's easytier-linux-<arch>), so it sidesteps the aarch64 rust/host
# build entirely. `feeds install -a` (run after this) symlinks both into package/feeds.
git clone https://github.com/EasyTier/luci-app-easytier --depth=1 clone/easytier
cp -rf clone/easytier/luci-app-easytier feeds/luci/applications/
cp -rf clone/easytier/easytier feeds/packages/net/
rm -rf clone

# Swap the core's raw `wget` for `curl -fL` in Build/Prepare. GNU wget can't parse
# socks5h:// (it errors "Unsupported scheme"), so a local build behind the project's
# socks5 proxy fails to fetch the binary; curl reads all_proxy/ALL_PROXY from the env
# (both exported by setup_proxy) and speaks socks5h natively. CI has no proxy, so
# wget vs curl is a wash there. Guarded: fail loudly if the wget line ever moves.
et_mk="feeds/packages/net/easytier/Makefile"
if grep -q 'wget .*releases/download' "$et_mk"; then
	sed -i '/releases\/download/{s/wget /curl -fL /; s/ -O / -o /;}' "$et_mk"
else
	echo "WARN: easytier Makefile has no wget release-download line — upstream changed it, skipping curl swap." >&2
fi

# Drop two conflicting FMSH SPI-NAND backport patches (upstream regression, 2026-08-24).
# ImmortalWrt's "Merge Official Source" pulled mainline backports 436/437 (add
# FM25G{01,02}B support) on top of its own Rockchip-based hack-6.12/400 fmsh.c, whose
# layout differs — 436 Hunk #1 can't find its anchor (FM25S01BI3_STATUS_ECC_MASK),
# so `make defconfig`/kernel-headers dies applying it (world Error 2). FMSH SPI-NAND
# is used by NONE of our profiles (N1 eMMC, x86, armvirt), so dropping both is safe.
# Idempotent (rm -f). Remove this block once upstream reconciles 400 with 436/437.
for p in 436-v7.3-mtd-spinand-fmsh-add-support-for-FM25G01B-FM25G02B \
	437-v7.3-mtd-spinand-fmsh-fix-FM25G01B-FM25G02B-Quad-IO-read-dummy-cycles; do
	f="target/linux/generic/backport-6.12/${p}.patch"
	if [ -f "$f" ]; then
		rm -f "$f"
		echo "INFO: dropped conflicting FMSH backport patch: $p" >&2
	fi
done
