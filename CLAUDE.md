# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in this repository.

## Project Overview

This repository is a customization and packaging layer for an ImmortalWrt-based Phicomm N1 bypass-router image. The upstream ImmortalWrt source is cloned during the build; this repo mainly provides:

- the N1 build profile under `armsr/armv8/N1/`
- feed/package customization in `armsr/armv8/diy/diy.sh`
- N1 rootfs overlay files in `armsr/armv8/N1/files/`
- the workflow that assembles and publishes the firmware in `.github/workflows/armsr_armv8.yml`

The current image direction is bypass-router mode with a bundled service set (PassWall + AdGuardHome + SNMP + KMS) rather than a full-featured OpenWrt distribution. Service business config — PassWall's node (`socks://192.168.0.8:1180`) + shunt rules, AdGuardHome's yaml (upstream, filters, rewrites), SNMP/KMS enablement — is baked in via the overlay, so flashing produces a ready-to-use router.

## Build Flow

The GitHub Actions workflow is the authoritative build recipe:

1. Clone `immortalwrt/immortalwrt` at `openwrt-25.12`
2. Run `armsr/armv8/diy/diy.sh` to patch feeds and pull in `luci-app-amlogic`
3. Replace the upstream `openwrt/files` and `openwrt/.config` with `armsr/armv8/N1/files` and `armsr/armv8/N1/.config`
4. Run `make defconfig`
5. Run `make download`
6. Compile the image with `make -j$(nproc)+1` and fall back to `make -j1 V=s` on failure
7. Package the resulting `*rootfs.tar.gz` with `ophub/amlogic-s9xxx-openwrt`

When changing package selection or overlay content, keep that flow in mind. The workflow expects a `rootfs.tar.gz` artifact.

The workflow layers a few build-speed/reliability tweaks on top of this recipe: it appends `CONFIG_CCACHE=y` to `.config` and persists both `dl/` and `.ccache` across runs via `actions/cache`, retries `feeds update -a` up to 3 times, and pins third-party actions to a released tag or commit SHA — except `ophub/amlogic-s9xxx-openwrt`, which tracks `@main` so packaging always uses the latest ophub tooling (matching `bin/build.sh`, which follows ophub `main` too). These do not change the build output.

## Common Commands

### Inspect build inputs

```bash
rg -n "^CONFIG_PACKAGE_.*=y|CONFIG_TARGET_" armsr/armv8/N1/.config
rg -n "luci-app|amlogic|clone" armsr/armv8/diy/diy.sh armsr/armv8/N1/files
```

### Validate shell and config files

```bash
sh -n armsr/armv8/N1/files/etc/uci-defaults/99-bypass-router
```

### Local build (preferred)

`bin/build.sh` reproduces the workflow natively (no Docker). From the repo root:

```bash
./bin/build.sh
```

Firmware lands in `$ARTIFACT_DIR/bin/targets/armsr/armv8/` (default `/opt/openwrt-build/output/...` on the native volume; set `ARTIFACT_DIR=./output` to pull it back into the repo). Key details:

- The OpenWrt tree builds under `BUILD_ROOT` (default `/opt/openwrt-build`), which **must** be a native ext4/xfs/btrfs volume — virtiofs/macOS mounts corrupt OpenWrt's many small parallel writes. The script refuses to run if `BUILD_ROOT` is on virtiofs/fuseblk/nfs/cifs/9p.
- `dl/`, `feeds/`, and ccache persist under `BUILD_ROOT/cache` so rebuilds reuse downloads and objects. `dl/` and `feeds/` are symlinks into that cache. Because a warm `feeds/` still carries `diy.sh`'s mutations (the `luci.patch`, the copied-in `luci-app-amlogic`), the script resets every cached feed repo to pristine (`git reset --hard` + `clean -fdx`) before each run, then re-runs `feeds update`/`diy.sh`. The reset is a near-free local git op; caching `feeds/` avoids re-cloning every feed repo over the proxy on each rebuild — worth it here because local builds are frequent and go through `ALL_PROXY`. The workflow deliberately does **not** cache `feeds/` (only `dl/` + `.ccache`): its runners are ephemeral and it runs only twice a month, so a fresh clone is simpler and avoids stale metadata, and it never needs the reset machinery.
- A prebuilt Go must exist at `GO_BOOTSTRAP` (default `/usr/local/go-bootstrap`) as an external bootstrap (OpenWrt Go >=1.26 needs a >=1.24.6 bootstrap, unsupported from source on arm64). The script prints install instructions if it is missing.
- All outbound fetches default to `socks5h://192.168.0.8:1180`; override with `ALL_PROXY`. Other tunables: `BUILD_ROOT`, `JOBS`, `REPO_BRANCH`, `OPHUB_REPO`, `INCREMENTAL`.

By default every run is a full clean build: it wipes and re-clones the openwrt tree, resets feeds to pristine, re-runs `diy.sh`, and does a full `make` (same as the workflow — deliberate, for reproducibility). ccache/`dl/`/`feeds/` caches only save re-downloads and repeated compile units, not the extract→configure→install passes, so a clean build never reaches packaging in "a few minutes". One opt-in fast path exists for local iteration (default off):

- `INCREMENTAL=1` reuses a warm openwrt tree — skips clone/feeds/`diy.sh` and lets `make` rebuild only what changed. It re-stamps the overlay + `.config` each run, so package/overlay edits **are** picked up; `diy.sh` edits are **not** (those patch pristine source — run a full build), and a toolchain/kernel `.config` change may still need one. Falls back to a full build if no warm tree (`.config`) is present.

The GitHub workflow has no equivalent: its runners are ephemeral, so it is always a full clean build.

After `bin/targets` is populated, the script packages the `*rootfs.tar.gz` into a flashable N1 `*.img.gz` via ophub (cloned to `BUILD_ROOT/ophub`, `main`), mirroring the workflow's "Package N1 firmware" step (`-b s905d -k 6.12.y -r ophub/kernel -u flippy -s 256/1024 -n mrabit`). The finished `*.img.gz` is moved into the repo's `dist/` dir (git-ignored). The packaging step lives in `bin/package.sh` and is invoked automatically at the end of `bin/build.sh`, so a build always ends with a flashable image; `bin/package.sh` can also be run standalone against a prior build's `bin/targets` without recompiling. It needs passwordless `sudo` (loop mount + `mkfs`) and errors out if unavailable.

On a shared-kernel host (OrbStack et al.) the builtin `loop` driver runs with `max_part=0`, so `losetup -P` yields a device but never creates the `p1`/`p2` partition nodes — ophub's `remake` then fails the bootfs mount (`[ 10 ] attempts to mount ... failed`). After refreshing the ophub clone, `bin/package.sh` patches `remake` to force the nodes with `partx -d`/`partx -a` (an ioctl that ignores `max_part`) right after its `losetup` call. The patch is guarded (idempotent, re-applied each run since the ophub reset restores pristine `remake`, WARNs if the anchor ever moves).

### Local build reproduction (manual)

Use the same sequence as the workflow inside a cloned ImmortalWrt tree:

```bash
git clone https://github.com/immortalwrt/immortalwrt -b openwrt-25.12 --single-branch --depth=1 openwrt
cd openwrt
./scripts/feeds update -a
/path/to/N1-OpenWrt/armsr/armv8/diy/diy.sh
./scripts/feeds update -a
./scripts/feeds install -a
rm -rf files .config
cp -r /path/to/N1-OpenWrt/armsr/armv8/N1/files ./files
cp /path/to/N1-OpenWrt/armsr/armv8/N1/.config ./.config
make defconfig
make download -j"$(nproc)" 2>/dev/null
make -j$(( $(nproc) + 1 )) || make -j1 V=s
```

### Single-target verification

There is no dedicated unit-test suite in this repository. Use targeted validation instead:

```bash
sh -n armsr/armv8/N1/files/etc/uci-defaults/99-bypass-router
```

If a build is already available locally, check the generated image contents rather than inventing a new test harness.

## Repository Structure

### `armsr/armv8/diy/diy.sh`

This is the feed and package customization hook. It currently:

- applies `luci.patch` to the upstream source
- clones `luci-app-amlogic` and copies it into `feeds/luci/applications/`
- drops `luci-app-attendedsysupgrade` from the default luci collection

The bypass-router service set (PassWall + AdGuardHome + SNMP + KMS) is now bundled directly in `.config` (see the `# bypass router services` block), mirroring the post-flash `apk add` list from the deployment runbook. Their symbols come from the stock ImmortalWrt feeds (proven by `apk add` succeeding against the SNAPSHOT repo, which is built from the same feeds), so no extra feed or `diy.sh` change is needed — PassWall's cores (`xray-core`, `sing-box`, `chinadns-ng`, `geoview`, `ipt2socks`) are pulled in as dependencies by `make defconfig`. PassWall also defaults to `shadowsocks-rust-sslocal`/`-ssserver` (its `INCLUDE_Shadowsocks_Rust_*` options are `default y` on aarch64), which are explicitly disabled in `.config`: they pull `rust/host`, and the OpenWrt rust package hardcodes `download-ci-llvm=true`, whose prebuilt-LLVM download 404s on aarch64 build hosts (rust CI only ships it for x86_64/aarch64-darwin). SS stays fully covered by `sing-box`/`xray-core`; the node and AGH business config are baked in via `files/` + `99-bypass-router` (see below). If a package is missing from the selected ImmortalWrt feeds and needs to ship, `diy.sh` is the first place to extend. Keep changes minimal and tied to package availability.

### `armsr/armv8/N1/.config`

This is the build profile for the N1 image. It controls the target, rootfs artifact, and the package set that gets compiled into the firmware.

### `armsr/armv8/N1/files/`

This overlay becomes the root filesystem content in the final image. It currently carries:

- `etc/config/network` — baseline LAN (static `192.168.0.4/24`, gateway `192.168.0.1`, packet steering)
- `etc/uci-defaults/99-bypass-router` — first-boot bypass-router setup (disables DHCP, enables IPv4 forwarding + software flow offloading, sets timezone and CN NTP servers; self-deletes after success). Hardware offloading and fullcone NAT are kept off: the S905D has no hardware flow offload, and enabling `flow_offloading_hw`/`fullcone` makes firewall4 fail to load its ruleset. It also re-points `/etc/resolv.conf` at the netifd-generated `/tmp/resolv.conf.d/resolv.conf.auto` (which carries the `network.lan.dns` upstreams) instead of the stock `127.0.0.1` stub — in bypass mode nothing serves `127.0.0.1:53` at boot, so leaving the stub breaks the router's own resolution (and `apk`). netifd rebuilds the auto file from `network.lan.dns` each boot, so the link self-heals. It also sets `dnsmasq` `port=0` and stops/disables it so AdGuardHome can bind `:53` (dnsmasq would otherwise race it, and PassWall re-pulls dnsmasq up), and it enables + configures the preinstalled services: SNMP read-only community is restricted to the LAN (`public.source=192.168.0.0/24`), and KMS/vlmcsd is enabled (`auto_activate` left `0`). PassWall's node + shunt rules and AdGuardHome's yaml (upstream, filters, rewrites) are also baked in via `files/` (`etc/adguardhome/adguardhome.yaml`, `usr/share/passwall/rules/proxy_host`) plus the uci sets above. It also writes the `luci-app-amlogic` (晶晨宝盒) config — OTA source (`amlogic_firmware_repo=mrabit/N1-OpenWrt`, tag `OpenWrt`, `.img.gz`), kernel source, `write_bootloader`/`shared_fstype`, and CPU governor. This **must** be done at first boot rather than as a static `etc/config/amlogic` overlay file: ophub's `remake` packaging step unconditionally overlays its own `common-files/etc/config/amlogic` (repo → ophub official, btrfs, schedutil) on top of the rootfs (`remake` ~line 914, `cp -af "${common_files}/." "${tag_rootfs}"`), so any static file is clobbered before the image is built. The uci-defaults runner executes after that overlay, so re-asserting the values there wins. Caveat: `amlogic_check_firmware.sh` fetches the releases HTML anonymously with bare `curl` (no token support), so `amlogic_firmware_repo` **must point at a public repo** or OTA update-checks 404 — keep `mrabit/N1-OpenWrt` public for OTA to work.
- `etc/crontabs/root` — scheduled `fstrim`

Treat files under this tree as runtime defaults, not build-time source code.

### `bin/build.sh`

Native local build (no Docker). Self-contained: clones ImmortalWrt, runs `diy.sh`, applies the N1 overlay/config, and compiles, publishing firmware to `$ARTIFACT_DIR/bin/targets` (default `BUILD_ROOT/output`). It keeps the throwaway openwrt tree and the `dl/`/feeds/ccache caches under `BUILD_ROOT` (a native volume, default `/opt/openwrt-build`) to avoid virtiofs corruption, uses a prebuilt Go at `GO_BOOTSTRAP` as an external bootstrap, and routes outbound fetches through `ALL_PROXY`. At the end it invokes `bin/package.sh` to package the `rootfs.tar.gz` into an ophub `*.img.gz` (moved into the repo's `dist/` dir). Tunable via `BUILD_ROOT`/`ARTIFACT_DIR`/`GO_BOOTSTRAP`/`ALL_PROXY`/`JOBS`/`REPO_BRANCH`/`OPHUB_REPO` env vars.

### `bin/package.sh`

Standalone packaging step (also called automatically by `bin/build.sh`): repackages an existing `$BUILD_ROOT/build/openwrt/bin/targets/armsr/armv8/*rootfs.tar.gz` into a flashable N1 `*.img.gz` via ophub, mirroring the workflow's "Package N1 firmware" step. Skips clone/feeds/compile entirely; requires a prior build and passwordless `sudo`. Tunable via `BUILD_ROOT`/`ALL_PROXY`/`OPHUB_REPO`.

## Working Notes

- Preserve the current packaging flow unless a change is required by evidence.
- PassWall node + AGH yaml are baked into `files/` by explicit choice; when the node address / rewrites change, update the overlay, not just the running router.
- When modifying `armsr/armv8/N1/.config`, verify the package symbols still survive `make defconfig`.
- When modifying overlay scripts, prefer idempotent first-boot behavior.
- Commits in this repo do not require GPG signing (overrides the global "all commits must be GPG-signed" rule).
