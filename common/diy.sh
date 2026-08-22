#!/bin/bash
# Shared feed/source customization for every profile (N1, x86, ...).
#
# Runs from the openwrt tree root, after `feeds update -a`. Applies the arch-
# agnostic patches and feed edits. Profile-specific diy scripts (e.g.
# armsr/armv8/N1/diy.sh) source this first, then add their own steps.
#
# COMMON_DIR is exported by the caller (build lib / workflow) and points at this
# file's directory; fall back to it when run standalone.
: "${COMMON_DIR:=$(cd "$(dirname "$0")" && pwd)}"

# Adjust source code: online-users LuCI fix (device-name aware /proc/net/arp parse).
patch -p1 -f < "$COMMON_DIR/luci.patch"

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
