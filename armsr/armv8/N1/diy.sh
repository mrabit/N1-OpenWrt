#!/bin/bash
# N1-specific feed/source customization. Runs from the openwrt tree root after
# `feeds update -a`. Applies the shared steps, then pulls in luci-app-amlogic
# (晶晨宝盒) — the Amlogic OTA/flash UI, which is meaningless off Amlogic hardware.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
export COMMON_DIR="$REPO_ROOT/common"

# Shared: luci.patch + drop attendedsysupgrade.
bash "$COMMON_DIR/diy.sh"

# Clone + install luci-app-amlogic into the luci feed.
git clone https://github.com/ophub/luci-app-amlogic --depth=1 clone/amlogic
cp -rf clone/amlogic/luci-app-amlogic feeds/luci/applications/
rm -rf clone
