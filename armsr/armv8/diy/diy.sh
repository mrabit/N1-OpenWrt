#!/bin/bash

# Adjust source code
patch -p1 -f < $(dirname "$0")/luci.patch

# Clone packages
git clone https://github.com/ophub/luci-app-amlogic --depth=1 clone/amlogic

# Adjust packages
cp -rf clone/amlogic/luci-app-amlogic feeds/luci/applications/
sed -i '/luci-app-attendedsysupgrade/d' feeds/luci/collections/luci/Makefile

# Clean packages
rm -rf clone