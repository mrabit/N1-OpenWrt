# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in this repository.

## Project Overview

This repository is a customization and packaging layer for ImmortalWrt-based bypass-router images. Upstream ImmortalWrt is cloned during the build; this repo provides two build **profiles** that share one service stack:

- **N1** (`armsr/armv8/N1/`) — Phicomm N1 (Amlogic S905D), packaged by ophub into a flashable `*.img.gz`, ships `luci-app-amlogic`.
- **x86** (`x86/64/`) — x86/64 generic, OpenWrt emits a bootable `*-generic-squashfs-combined-efi.img.gz` directly (no ophub), no `luci-app-amlogic`.

Both profiles build from one unified workflow: `.github/workflows/build.yml`. A matrix `build` job compiles N1 and x86 in parallel (they share ~95% of the steps); a single `release` job then downloads every profile's image artifact and publishes **one combined release** (`firmware_<date>` + rolling `latest`, all images as assets in one place). N1 images are **additionally** pushed to the fixed `OpenWrt` tag that `luci-app-amlogic` OTA reads — x86 images never land there, so 晶晨宝盒 can't offer the wrong image. `workflow_dispatch` takes a `profile` input (`all`/`N1`/`x86`) to build a single profile on demand.

Shared, arch-agnostic pieces live in `common/`:

- `common/files/` — the rootfs overlay (network, `99-bypass-router`, AGH yaml, PassWall rules), used by both profiles.
- `common/config.services` — the shared package selection (service stack + common userland), appended onto each profile's `.config` before `make defconfig`.
- `common/diy.sh` — shared feed/source patches (`luci.patch`, drop attendedsysupgrade). `common/luci.patch` lives here too.

Each profile keeps only its target/rootfs/kmod-specific `.config`; N1 additionally has `armsr/armv8/N1/diy.sh` (sources `common/diy.sh`, then clones `luci-app-amlogic`). x86 uses `common/diy.sh` directly.

The current image direction is bypass-router mode with a bundled service set (PassWall + AdGuardHome + SNMP + KMS) rather than a full-featured OpenWrt distribution. Service business config — PassWall's node (`socks://192.168.0.8:1180`) + shunt rules, AdGuardHome's yaml (upstream, filters, rewrites), SNMP/KMS enablement — is baked into `common/files/`, so flashing produces a ready-to-use router. The `99-bypass-router` amlogic block is guarded by `[ -f /etc/config/amlogic ]`, so it self-skips on x86.

## Build Flow

Both profiles follow the same recipe (the GitHub Actions workflows are authoritative). For N1:

1. Clone `immortalwrt/immortalwrt` at `openwrt-25.12`
2. Run `armsr/armv8/N1/diy.sh` (→ `common/diy.sh` + `luci-app-amlogic`); x86 runs `common/diy.sh`
3. Replace upstream `openwrt/files` with `common/files`, and `openwrt/.config` with the profile's `.config` + `common/config.services` concatenated
4. Run `make defconfig`
5. Run `make download`
6. Compile with `make -j$(nproc)+1`, fall back to `make -j1 V=s` on failure
7. **N1 only:** package the `*rootfs.tar.gz` with `ophub/amlogic-s9xxx-openwrt`. **x86:** the combined-efi image is already bootable; just publish it.

When changing package selection or overlay content, keep that flow in mind. The N1 matrix leg expects a `rootfs.tar.gz` artifact (fed to ophub); the x86 leg expects a `*squashfs-combined-efi.img.gz`.

**Unified image naming.** Both the workflow and the `bin/` scripts rename the final published image (in `out/<profile>/` for the workflow, `dist/` for `bin/`) to one scheme so both profiles look alike in a release:

- N1: `immortalwrt_25.12_s905d_k<kernel>_<date>.img.gz` (e.g. `immortalwrt_25.12_s905d_k6.12.48_2026.08.21.img.gz`)
- x86: `immortalwrt_25.12_x86_64_k<kernel>_<date>.img.gz` (e.g. `immortalwrt_25.12_x86_64_k6.12.103_2026.08.21.img.gz`)

Structure is `immortalwrt_<op>_<board>_k<kernel>_<date>.img.gz`. The op version is **read from the built tree's `include/version.mk`** (`VERSION_NUMBER`, e.g. `25.12-SNAPSHOT`) with the `-SNAPSHOT` suffix stripped → `25.12`. This tracks the real upstream version: `openwrt-25.12` ships no patch level yet (`DISTRIB_RELEASE=25.12-SNAPSHOT` → `25.12`), but the moment upstream tags a real point release on that line (`25.12.1`), the image name follows automatically with no repo change. Each name site (workflow build stage, `bin/build-x86.sh`, `bin/package.sh`) parses `version.mk` from its own openwrt tree and **falls back to `REPO_BRANCH`** (`openwrt-25.12` → `25.12`) if the tree/line can't be read, so bumping the branch still bumps the name even without a tree. The `release` job has no source tree, so it derives `OP_VERSION` from the downloaded image filename's 2nd `_`-field (the build stage already baked the real version in) — the images are the single source of truth for the release notes, guaranteeing notes and image names always agree. The N1 `s905d_k6.12.NN` segment is **load-bearing**: `luci-app-amlogic` OTA matches `.*_s905d_.*k6.12.[0-9]+.*.img.gz`, so that segment (real kernel number, not `k6.12.y`) and the `.img.gz` suffix must survive any rename — the rest is free. The kernel number for N1 comes from ophub's own filename (its flippy kernel, ~`6.12.48`); for x86 it's parsed from the target `.manifest` (`^kernel` line, ImmortalWrt's own build, ~`6.12.103`) — the two are different kernels by design. The N1 date is reused from ophub's packaging date; x86's is generated locally (`TZ`-aware). The release job's `n1-only/` split still keys off `*_s905d_*.img.gz`, which the new N1 name still matches. **Gzip FNAME (N1 rename detail):** ophub's `gzip` records the pre-rename name (`openwrt_amlogic_...`) in the N1 image's gzip header FNAME field; renaming only the `.gz` shell leaves that stale, so `gunzip -N` / GUI extractors decompress to the old name (mismatching the shell). So N1 is **recompressed, not `cp`'d** — both name sites (workflow "Collect firmware", `bin/package.sh`) do `gzip -dc "$src" | gzip -n > "$dst"`: `gzip -n` writes no name/mtime, so extraction falls back to stripping `.gz` and the `.img` matches the shell (`gzip -dc`, not `zcat` — BSD `zcat` only groks `.Z`). Adds ~a few minutes (decompress ~1GB, recompress) but keeps names unified. x86 stores no FNAME, so it's a plain `cp`.

x86 op version is **read from the built tree's `include/version.mk`** (`VERSION_NUMBER`, e.g. `25.12-SNAPSHOT`) with `-SNAPSHOT` stripped → `25.12`; once upstream tags a real point release (`25.12.1`) the name follows automatically. Both x86 name sites (workflow build stage, `bin/build-x86.sh`) parse `version.mk` and **fall back to `REPO_BRANCH`** (`openwrt-25.12` → `25.12`) if unreadable. The `release` job has no source tree, so it derives `OP_VERSION` for the release notes from the **x86** image filename's 2nd `_`-field (only x86 carries a version there — N1's 2nd field is `amlogic`); it falls back to `REPO_BRANCH` if no x86 image is present (e.g. an N1-only manual build). The N1 kernel comes from ophub's filename (its flippy kernel, ~`6.12.48`); x86's from the target `.manifest` (`^kernel` line, ~`6.12.103`) — different kernels by design. The release job's `n1-only/` OTA split keys off `*_s905d_*.img.gz`, which ophub's name matches.

The workflow layers a few build-speed/reliability tweaks (applied to both matrix legs): it appends `CONFIG_CCACHE=y` to `.config` and persists `dl/` + `.ccache` across runs via `actions/cache` (keyed per profile), retries `feeds update -a` up to 3 times, and pins third-party actions to a released tag or commit SHA — except `ophub/amlogic-s9xxx-openwrt` (N1 leg only), which tracks `@main` so packaging always uses the latest ophub tooling (matching `bin/build.sh`, which follows ophub `main` too). These do not change the build output.

## Common Commands

### Inspect build inputs

```bash
rg -n "^CONFIG_PACKAGE_.*=y|CONFIG_TARGET_" armsr/armv8/N1/.config x86/64/.config common/config.services
rg -n "luci-app|amlogic|clone" common/diy.sh armsr/armv8/N1/diy.sh common/files
```

### Validate shell and config files

```bash
sh -n common/files/etc/uci-defaults/99-bypass-router
bash -n common/diy.sh armsr/armv8/N1/diy.sh bin/build.sh bin/build-lib.sh bin/build-N1.sh bin/build-x86.sh bin/package.sh
```

### Local build (preferred)

`bin/build.sh` reproduces the workflow natively (no Docker). It is a dispatcher: with no arg (and no `$PROFILE`) it builds **both** profiles in sequence (N1 then x86); pass a profile to build just one. N1 failing aborts before x86 runs. From the repo root:

```bash
./bin/build.sh          # both: N1, then x86
./bin/build.sh N1       # → bin/build-N1.sh only
./bin/build.sh x86      # → bin/build-x86.sh only
```

N1 firmware lands in `$ARTIFACT_DIR/bin/targets/armsr/armv8/`, x86 in `.../x86/64/` (default `/opt/openwrt-build/output/...` on the native volume; set `ARTIFACT_DIR=./output` to pull it back into the repo). x86 uses a separate scratch subtree (`BUILD_ROOT/build-x86`, `cache/feeds-x86`, `cache/ccache-x86`) so both profiles can coexist under one `BUILD_ROOT`. Key details:

- The OpenWrt tree builds under `BUILD_ROOT` (default `/opt/openwrt-build`), which **must** be a native ext4/xfs/btrfs volume — virtiofs/macOS mounts corrupt OpenWrt's many small parallel writes. The script refuses to run if `BUILD_ROOT` is on virtiofs/fuseblk/nfs/cifs/9p.
- `dl/`, `feeds/`, and ccache persist under `BUILD_ROOT/cache` so rebuilds reuse downloads and objects. `dl/` and `feeds/` are symlinks into that cache. Because a warm `feeds/` still carries `diy.sh`'s mutations (the `luci.patch`, the copied-in `luci-app-amlogic`), the script resets every cached feed repo to pristine (`git reset --hard` + `clean -fdx`) before each run, then re-runs `feeds update`/`diy.sh`. The reset is a near-free local git op; caching `feeds/` avoids re-cloning every feed repo over the proxy on each rebuild — worth it here because local builds are frequent and go through `ALL_PROXY`. The workflow deliberately does **not** cache `feeds/` (only `dl/` + `.ccache`): its runners are ephemeral and it runs only twice a month, so a fresh clone is simpler and avoids stale metadata, and it never needs the reset machinery.
- **N1 only:** a prebuilt Go must exist at `GO_BOOTSTRAP` (default `/usr/local/go-bootstrap`) as an external bootstrap (OpenWrt Go >=1.26 needs a >=1.24.6 bootstrap, unsupported from source on arm64). The script prints install instructions if it is missing. x86 can build Go from source, so `build-x86.sh` uses `GO_BOOTSTRAP` only if present and never hard-fails on its absence.
- All outbound fetches default to `socks5h://192.168.0.8:1180`; override with `ALL_PROXY`. Other tunables: `BUILD_ROOT`, `JOBS`, `REPO_BRANCH`, `OPHUB_REPO`, `INCREMENTAL`.

By default every run is a full clean build: it wipes and re-clones the openwrt tree, resets feeds to pristine, re-runs `diy.sh`, and does a full `make` (same as the workflow — deliberate, for reproducibility). ccache/`dl/`/`feeds/` caches only save re-downloads and repeated compile units, not the extract→configure→install passes, so a clean build never reaches packaging in "a few minutes". One opt-in fast path exists for local iteration (default off):

- `INCREMENTAL=1` reuses a warm openwrt tree — skips clone/feeds/`diy.sh` and lets `make` rebuild only what changed. It re-stamps the overlay + `.config` each run, so package/overlay edits **are** picked up; `diy.sh` edits are **not** (those patch pristine source — run a full build), and a toolchain/kernel `.config` change may still need one. Falls back to a full build if no warm tree (`.config`) is present.

The GitHub workflow has no equivalent: its runners are ephemeral, so it is always a full clean build.

**N1 only:** after `bin/targets` is populated, `build-N1.sh` packages the `*rootfs.tar.gz` into a flashable N1 `*.img.gz` via ophub (cloned to `BUILD_ROOT/ophub`, `main`), mirroring the workflow's "Package N1 firmware" step (`-b s905d -k 6.12.y -r ophub/kernel -u flippy -s 256/1024 -n mrabit`). The finished `*.img.gz` is moved into the repo's `dist/` dir (git-ignored) and renamed to the unified scheme (recompressed via `gzip -dc | gzip -n` to reset the FNAME header — see "Unified image naming" above). The packaging step lives in `bin/package.sh` and is invoked automatically at the end of `build-N1.sh`, so an N1 build always ends with a flashable image; `bin/package.sh` can also be run standalone against a prior build's `bin/targets` without recompiling. It needs passwordless `sudo` (loop mount + `mkfs`) and errors out if unavailable. **x86 has no packaging step** — `build-x86.sh` copies the already-bootable `*combined-efi.img.gz` from `bin/targets` into the same repo `dist/` dir (so both profiles land their final flashable image there), and WARNs if no combined-efi image is found (a sign the x86 `.config` GRUB/rootfs symbols got flipped by `make defconfig`).

On a shared-kernel host (OrbStack et al.) the builtin `loop` driver runs with `max_part=0`, so `losetup -P` yields a device but never creates the `p1`/`p2` partition nodes — ophub's `remake` then fails the bootfs mount (`[ 10 ] attempts to mount ... failed`). After refreshing the ophub clone, `bin/package.sh` patches `remake` to force the nodes with `partx -d`/`partx -a` (an ioctl that ignores `max_part`) right after its `losetup` call. The patch is guarded (idempotent, re-applied each run since the ophub reset restores pristine `remake`, WARNs if the anchor ever moves).

### Local build reproduction (manual)

Use the same sequence as the workflow inside a cloned ImmortalWrt tree:

Use the same sequence as the workflow inside a cloned ImmortalWrt tree (N1 shown; for x86 swap `armsr/armv8/N1/diy.sh` → `common/diy.sh` and `armsr/armv8/N1/.config` → `x86/64/.config`):

```bash
git clone https://github.com/immortalwrt/immortalwrt -b openwrt-25.12 --single-branch --depth=1 openwrt
cd openwrt
./scripts/feeds update -a
/path/to/N1-OpenWrt/armsr/armv8/N1/diy.sh          # x86: COMMON_DIR=/path/to/N1-OpenWrt/common /path/to/N1-OpenWrt/common/diy.sh
./scripts/feeds update -a
./scripts/feeds install -a
rm -rf files .config
cp -r /path/to/N1-OpenWrt/common/files ./files
cp /path/to/N1-OpenWrt/armsr/armv8/N1/.config ./.config   # x86: x86/64/.config
cat /path/to/N1-OpenWrt/common/config.services >> ./.config
make defconfig
make download -j"$(nproc)" 2>/dev/null
make -j$(( $(nproc) + 1 )) || make -j1 V=s
```

### Single-target verification

There is no dedicated unit-test suite in this repository. Use targeted validation instead:

```bash
sh -n common/files/etc/uci-defaults/99-bypass-router
```

If a build is already available locally, check the generated image contents rather than inventing a new test harness.

## Repository Structure

### `common/diy.sh` + `armsr/armv8/N1/diy.sh`

The feed/source customization hook, split shared vs profile-specific:

- `common/diy.sh` (shared, used by x86 directly): applies `common/luci.patch` to the upstream source; drops `luci-app-attendedsysupgrade` from the default luci collection. Expects `COMMON_DIR` in the env (the caller exports it; falls back to its own dir).
- `armsr/armv8/N1/diy.sh` (N1): sources `common/diy.sh`, then clones `luci-app-amlogic` and copies it into `feeds/luci/applications/`.

The bypass-router service set (PassWall + AdGuardHome + SNMP + KMS) is bundled in `common/config.services` (appended onto each profile's `.config`), mirroring the post-flash `apk add` list from the deployment runbook. Their symbols come from the stock ImmortalWrt feeds (proven by `apk add` succeeding against the SNAPSHOT repo, which is built from the same feeds), so no extra feed or `diy.sh` change is needed — PassWall's cores (`xray-core`, `sing-box`, `chinadns-ng`, `geoview`, `ipt2socks`) are pulled in as dependencies by `make defconfig`. PassWall also defaults to `shadowsocks-rust-sslocal`/`-ssserver` (its `INCLUDE_Shadowsocks_Rust_*` options are `default y` on aarch64), which are explicitly disabled: they pull `rust/host`, and the OpenWrt rust package hardcodes `download-ci-llvm=true`, whose prebuilt-LLVM download 404s on aarch64 build hosts (rust CI only ships it for x86_64/aarch64-darwin) — kept off on x86 too for parity since `sing-box`/`xray-core` already cover SS. The node and AGH business config are baked in via `common/files/` + `99-bypass-router` (see below). If a package is missing from the selected ImmortalWrt feeds and needs to ship, `common/diy.sh` (or the profile's) is the first place to extend. Keep changes minimal and tied to package availability.

### `armsr/armv8/N1/.config` + `x86/64/.config` + `common/config.services`

Each profile's `.config` controls only its target, rootfs artifact, and arch-specific packages (kmod, packaging tooling). N1 targets `armsr/armv8` → `rootfs.tar.gz` (for ophub); x86 targets `x86/64` → EFI combined squashfs image. `common/config.services` holds the shared service stack + common userland and is **appended** onto the profile `.config` before `make defconfig` (by the build lib and the workflow's matrix legs). To reconstruct what a profile actually builds, read both files together.

**N1 WiFi (open AP bridged to LAN, N1-only).** Shipped default: N1 broadcasts an **open AP `N1-OpenWrt`** bridged into the LAN, so wireless clients join `192.168.0.0/24` and get DHCP from the main router — same L2 as wired clients. N1's `.config` enables `kmod-cfg80211 kmod-mac80211 kmod-brcmutil kmod-brcmfmac wpad-basic-mbedtls` — deliberately **not** in `common/config.services`, since x86 has no board WiFi and the user scoped this to N1. The N1 board WiFi is a Broadcom **BCM43455 (AP6255)** on SDIO. The split of responsibility is load-bearing: the actual driver modules (`brcmfmac.ko` + the BCM43455-required `brcmfmac-wcc.ko`, `cfg80211.ko`, `mac80211.ko`, `brcmutil.ko`) come from **flippy's kernel** — remake wipes `${tag_rootfs}/lib/modules/*` (remake ~line 910) and extracts flippy's modules tarball, so any `.ko` these OpenWrt packages build is discarded (and would mismatch flippy's vermagic anyway). Verified present in the flippy 6.12.y kernel (ophub packages `-k 6.12.y`, so the exact point release tracks ophub's latest at build time). The **firmware blob + NVRAM** (`brcmfmac43455-sdio.phicomm,n1.bin/.txt`, generic `.bin`, `.clm_blob`) ship in ophub's `common-files/lib/firmware/brcm/` and land in the rootfs via remake's `cp -af common-files/. tag_rootfs` (remake ~line 914) — N1-specific calibration, not a generic fallback. So the OpenWrt packages are selected **only for their userspace glue**: `kmod-mac80211` drags in `wifi-scripts` (`/sbin/wifi`, `/lib/netifd/wireless/mac80211.sh`), `iw`, `iwinfo`, `wireless-regdb` — the netifd/LuCI integration that lets the radio be detected and configured. Those files live outside `/lib/modules`, so remake's module swap leaves them intact. `@USB_SUPPORT=y` on armsr satisfies `kmod-brcmfmac`'s hard dep, so all five survive `make defconfig`. The LuCI wireless page is built into `luci-mod-network` (already pulled by the `luci` meta-package) — there is **no** `luci-proto-wireless` package in current LuCI, so don't add one.

The AP config is shipped as `armsr/armv8/N1/files/etc/config/wireless` (a **per-profile files layer** — `armsr/armv8/N1/files/` overlays `common/files/`; `bin/build-*.sh` already do this via `PROFILE_DIR/files`, and the workflow's "Load custom config" step overlays `$(dirname matrix.config)/files` after `common/files`). It defines `radio0` (SDIO `path` from the real N1, band `2g`/ch1, country CN) + one AP iface (`N1-OpenWrt`, `encryption none`, `network lan`). Two reasons it's a static file and **STA is deliberately absent**: (a) shipping a complete `/etc/config/wireless` suppresses first-boot auto-generation of the junk AP (gotcha #2 below); (b) an STA section carries the home WiFi's plaintext PSK, which must never enter git — a user wanting STA client mode adds it in LuCI instead. For the AP to bridge into the LAN, `common/files/etc/config/network` makes `lan` a **bridge** (`br-lan` with port `eth0`); a wifi-iface with `network 'lan'` then joins that L2. Wired LAN `192.168.0.4` and the wired uplink are unchanged. **Security:** the AP is open — anyone in range joins the internal `192.168.0.0/24`; the user accepted this. If the radio doesn't appear after flashing, `wifi config` regenerates it (but then re-check for the junk AP).

**Two N1 WiFi runtime gotchas (verified on real hardware, flippy 6.12.y)** — only relevant if this box is ever switched from the shipped AP mode to STA client mode; the AP config already avoids both:

1. **STA mode needs `roamoff=1` or it flaps forever** — *not shipped* (the AP default doesn't use it; `roamoff` only affects STA/client behaviour). If you reconfigure N1 as a WiFi *client*, add `/etc/modprobe.d/brcmfmac.conf` with `options brcmfmac roamoff=1` and reload the module, or the STA associates + gets a DHCP lease but ~10s later wpa_supplicant logs `Authentication timed out` + a `locally_generated reason=3` deauth and flaps forever. Root cause is brcmfmac's **firmware background roaming** disrupting the link — not encryption or band (reproduced identically across SAE↔psk2 and 5G↔2.4G); a client only ever talks to one AP so roaming is useless anyway. This brcmfmac build has **no** `feature_disable` param (the RPi-forum value is inapplicable) — `roamoff` alone is the fix. `/etc/modprobe.d/` applies because OpenWrt loads brcmfmac via `modprobe` at boot.
2. **FullMAC can't do AP+STA; first boot otherwise auto-generates a junk AP** — the BCM43455 is **FullMAC** (`iwinfo` → `Supports VAPs: no`), so only one wifi-iface (AP *or* STA) can run per radio. If `/etc/config/wireless` is absent, ImmortalWrt's `wifi config` writes a `default_radio0` iface in **AP mode, SSID `ImmortalWrt`, open, `disabled '0'`** on `lan` — and if a user then adds an STA, hostapd's AP attempt fails (`AP-DISABLED`/`wasn't started`), leaves the radio busy (`scan-failed ret=-16`), and the STA can't hold. We avoid this entirely by **shipping** a complete `/etc/config/wireless` (above), so auto-gen never runs. Anyone switching this box to STA client mode must **delete/disable the AP iface first** (two ifaces = the same conflict). Also: brcmfmac + wpa_supplicant sched-scan is flaky in STA mode — leaving `radio0` on a band with no fixed channel loops `Failed to initiate sched scan`; pin `option channel` to the AP's actual channel (the STA needs the radio pinned to the target AP's band/channel, e.g. our target was 2.4G ch1).

### `common/files/`

This overlay becomes the root filesystem content in the final image, shared by both profiles. It currently carries:

- `etc/config/network` — baseline LAN as a **bridge** (`br-lan` with port `eth0`, static `192.168.0.4/24`, gateway `192.168.0.1`, packet steering). Bridged so the N1 WiFi AP can join the LAN's L2; identical to direct-eth0 when no wifi is attached, and stock OpenWrt's default lan shape.
- `etc/uci-defaults/99-bypass-router` — first-boot bypass-router setup (disables DHCP, enables IPv4 forwarding + software flow offloading, enables LAN-zone masquerade, sets timezone; self-deletes after success). **NTP servers are deliberately NOT set here:** ImmortalWrt's own `default-settings` package ships `/etc/uci-defaults/99-default-settings-chinese`, which sorts *after* `99-bypass-router` (uci-defaults run in filename order; `-`=0x2d < `d`=0x64) and `delete`s then rewrites `system.ntp.server` to its CN list (`ntp.tencent.com` / `ntp1.aliyun.com` / `ntp.ntsc.ac.cn` / `cn.ntp.org.cn`, incl. 国家授时中心). Anything we set is clobbered, so we adopt its list (a superset of the old aliyun/tencent/cn.pool trio) and only keep the timezone set (it sets the same timezone value too, so order doesn't matter there). This was diagnosed from a real first-boot N1 whose NTP list came up as the stock 4 while every other uci change survived. Hardware offloading and fullcone NAT are kept off: the S905D has no hardware flow offload, and enabling `flow_offloading_hw`/`fullcone` makes firewall4 fail to load its ruleset; kept off for x86 too (generic NICs lack hw offload). **LAN-zone masquerade (`firewall.@zone[0].masq=1`) is on** — this is a single-arm bypass router with no `wan` interface (only `br-lan`), so the stock firewall's `wan`-zone masquerade never fires. Traffic PassWall routes **direct** (China IPv4 that skips the proxy) is forwarded br-lan→br-lan back to the main gateway with the client's source IP unchanged; the reply then returns straight to the client (not via N1), and some upstream routers drop that asymmetric flow — so every China-direct site silently times out (SYN sent, `[UNREPLIED]` in conntrack) while proxied/IPv6 traffic works. Enabling LAN masq SNATs the direct flows to N1's own IP so the reply comes back through N1 (conntrack goes `[ASSURED]`). Trade-off: the main router sees all direct traffic as coming from N1 (`192.168.0.4`), losing per-client visibility — acceptable for a bypass gateway. Proxied traffic is unaffected (it's redirected to the local sing-box `:1041` at PREROUTING, never hits the forward/srcnat path). Diagnosed from a real client whose gateway+DNS pointed at N1: ip138.com and other China-direct sites timed out at the TCP handshake until masq was enabled. The amlogic block below is guarded by `[ -f /etc/config/amlogic ]`, so it only runs on N1 and self-skips on x86. It also re-points `/etc/resolv.conf` at the netifd-generated `/tmp/resolv.conf.d/resolv.conf.auto` (which carries the `network.lan.dns` upstreams) instead of the stock `127.0.0.1` stub — in bypass mode nothing serves `127.0.0.1:53` at boot, so leaving the stub breaks the router's own resolution (and `apk`). netifd rebuilds the auto file from `network.lan.dns` each boot, so the link self-heals. It also sets `dnsmasq` `port=0` and stops/disables it so AdGuardHome can bind `:53` (dnsmasq would otherwise race it, and PassWall re-pulls dnsmasq up), and it enables + configures the preinstalled services: SNMP read-only community is restricted to the LAN (`public.source=192.168.0.0/24`), and KMS/vlmcsd is enabled (`auto_activate` left `0`). PassWall's node + shunt rules and AdGuardHome's yaml (upstream, filters, rewrites) are also baked in via `files/` (`etc/adguardhome/adguardhome.yaml`, `usr/share/passwall/rules/proxy_host`) plus the uci sets above. It also writes the `luci-app-amlogic` (晶晨宝盒) config — OTA source (`amlogic_firmware_repo=mrabit/N1-OpenWrt`, tag `OpenWrt`, `.img.gz`), kernel source, `write_bootloader`/`shared_fstype`, and CPU governor. This **must** be done at first boot rather than as a static `etc/config/amlogic` overlay file: ophub's `remake` packaging step unconditionally overlays its own `common-files/etc/config/amlogic` (repo → ophub official, btrfs, schedutil) on top of the rootfs (`remake` ~line 914, `cp -af "${common_files}/." "${tag_rootfs}"`), so any static file is clobbered before the image is built. The uci-defaults runner executes after that overlay, so re-asserting the values there wins. Caveat: `amlogic_check_firmware.sh` fetches the releases HTML anonymously with bare `curl` (no token support), so `amlogic_firmware_repo` **must point at a public repo** or OTA update-checks 404 — keep `mrabit/N1-OpenWrt` public for OTA to work.
- `etc/crontabs/root` — scheduled `fstrim`

Treat files under this tree as runtime defaults, not build-time source code.

### `bin/build.sh` (dispatcher) + `bin/build-lib.sh` (shared) + `bin/build-N1.sh` / `bin/build-x86.sh`

`bin/build.sh` is a thin dispatcher: it resolves the profile from the first positional arg or `$PROFILE`. With no profile it runs **both** in sequence (`build-N1.sh` then `build-x86.sh`, aborting before x86 if N1 fails); with a profile it runs just that one. All tunables pass through the environment.

`bin/build-lib.sh` holds all the machinery the two profile builds share (~90% of the old scripts was duplicated): the common tunable defaults, the sanity checks (`check_buildroot_fs`/`check_disk`/`check_go_bootstrap`), `ensure_deps`, `setup_proxy`, `update_feeds`, `apply_overlay`, the full/incremental `do_build`, `publish_artifacts`, `print_build_time`, and `derive_op_version` (the `version.mk` parse, reused by `package.sh` too). It's a **pure function library** — sourcing sets the common defaults + defines functions but runs nothing; each wrapper drives the call order. A wrapper sets `PROFILE_DIR`, the scratch/cache names, `GO_REQUIRED` (1 on N1, 0 on x86 — controls whether the external Go bootstrap is mandatory), a banner, and a `run_diy()` hook, then sources the lib and calls the functions.

- `bin/build-N1.sh` (~76 lines) — sets the N1 profile dir + scratch tree (`BUILD_ROOT/build`, `cache/feeds`, `cache/ccache`), `GO_REQUIRED=1`, `run_diy(){ bash armsr/armv8/N1/diy.sh; }`; runs the shared flow, then invokes `bin/package.sh` to ophub-package the `rootfs.tar.gz` into `*.img.gz` (moved into `dist/`). Requires a prebuilt Go at `GO_BOOTSTRAP`.
- `bin/build-x86.sh` (~101 lines) — sets the x86 profile dir + its own scratch subtree (`BUILD_ROOT/build-x86`, `cache/feeds-x86`, `cache/ccache-x86`, so it never collides with an N1 build), `GO_REQUIRED=0`, `run_diy(){ COMMON_DIR=… bash common/diy.sh; }`; runs the shared flow, then (**no ophub step**) copies the already-bootable `*combined-efi.img.gz` from `bin/targets` into `dist/`, renamed to the unified scheme via `derive_op_version` (see "Unified image naming"). `GO_BOOTSTRAP` optional. `dl/` is shared with N1 (same downloads); only feeds/ccache are per-profile.

Both keep the throwaway openwrt tree + caches under `BUILD_ROOT` (native volume, default `/opt/openwrt-build`) to avoid virtiofs corruption, and route outbound fetches through `ALL_PROXY`. Tunable via `BUILD_ROOT`/`ARTIFACT_DIR`/`GO_BOOTSTRAP`/`ALL_PROXY`/`JOBS`/`REPO_BRANCH`/`OPHUB_REPO`/`INCREMENTAL` (defaults live in `build-lib.sh`).

### `bin/package.sh`

Standalone packaging step (also called automatically by `bin/build-N1.sh`, **N1 only**): repackages an existing `$BUILD_ROOT/build/openwrt/bin/targets/armsr/armv8/*rootfs.tar.gz` into a flashable N1 `*.img.gz` via ophub, mirroring the workflow's "Package N1 firmware" step. Skips clone/feeds/compile entirely; requires a prior build and passwordless `sudo`. Sources `bin/build-lib.sh` only to reuse `derive_op_version` for the image name (sourcing has no side effects). Tunable via `BUILD_ROOT`/`ALL_PROXY`/`OPHUB_REPO`. Not used by the x86 profile.

## Working Notes

- Preserve the current packaging flow unless a change is required by evidence.
- The overlay + service stack are shared in `common/`; edits there hit **both** profiles. Only put arch/target-specific bits in a profile's `.config` (or a profile `files/`, which layers on top of `common/files`).
- PassWall node + AGH yaml are baked into `common/files/` by explicit choice; when the node address / rewrites change, update the overlay, not just the running router.
- When modifying any `.config` or `common/config.services`, verify the package symbols still survive `make defconfig` — remember a profile's effective config is `<profile>/.config` + `common/config.services` concatenated.
- x86 `.config` GRUB symbols (`CONFIG_GRUB_EFI_IMAGES`, `CONFIG_TARGET_IMAGES_GZIP`) are **verified good** — a real build produced both `squashfs-` and `ext4-generic-combined-efi.img.gz` (squashfs is the sysupgrade-friendly one for routers). The grub-bios-setup "BIOS Boot Partition under 1 MiB" line is a harmless warning (EFI boot only). `CONFIG_TARGET_ROOTFS_PARTSIZE=1024` is **required**: the default 160 MiB is too small for the bundled service stack and the build dies at `target/linux/install` with an ext4 "out of space" error (see [[x86-rootfs-partsize]] memory). If a future package overflows it again, bump PARTSIZE and debug fast with `make target/linux/install V=s` (no recompile).
- When modifying overlay scripts, prefer idempotent first-boot behavior.
- Commits in this repo do not require GPG signing (overrides the global "all commits must be GPG-signed" rule).
