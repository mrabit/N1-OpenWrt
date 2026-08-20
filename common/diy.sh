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
