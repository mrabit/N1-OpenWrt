#!/usr/bin/env bash
# Shared build machinery for the native (no-Docker) profile builds. Sourced by
# bin/build-N1.sh and bin/build-x86.sh; also sourced by bin/package.sh purely to
# reuse derive_op_version(). Sourcing has NO side effects beyond setting the
# common tunable defaults below and defining functions — the wrappers drive the
# order by calling the functions themselves.
#
# A wrapper sets, before sourcing this file: PROFILE_NAME, REPO_ROOT, COMMON_DIR,
# PROFILE_DIR, OUTDIR, FEEDS_CACHE, CCACHE_DIR, LOG, GO_REQUIRED (1/0), and a
# run_diy() hook (invoked from the openwrt tree root on the full-build path).

# --- common tunable defaults -------------------------------------------------
: "${REPO_BRANCH:=openwrt-25.12}"
: "${REPO_URL:=https://github.com/immortalwrt/immortalwrt}"
# Native scratch area for the throwaway openwrt tree + persistent caches.
: "${BUILD_ROOT:=/opt/openwrt-build}"
# Prebuilt Go used as external bootstrap (Go >=1.26 needs bootstrap >=1.24.6;
# on arm64 the source bootstrap from go1.4 is unsupported). Required by N1,
# optional on x86 (which can build Go from source).
: "${GO_BOOTSTRAP:=/usr/local/go-bootstrap}"
# Outbound proxy; go.dev / some feeds are unreachable directly here.
# socks5h keeps DNS resolution on the proxy side.
: "${ALL_PROXY:=socks5h://192.168.0.8:1180}"
: "${JOBS:=$(nproc)}"
# Where the finished firmware is copied. Defaults to the native scratch volume
# to keep the repo (often a slow virtiofs mount) clean; override to taste.
: "${ARTIFACT_DIR:=$BUILD_ROOT/output}"
# Fast path for local iteration; default off (full clean build otherwise).
#   INCREMENTAL=1  reuse a warm openwrt tree: skip clone/feeds/diy.sh and let make
#                  rebuild only what changed. Re-applies the overlay/.config each
#                  run, so package/overlay edits ARE picked up; diy.sh edits are
#                  NOT (those patch pristine source — run a full build). A
#                  toolchain/kernel .config change may still need a full rebuild.
: "${INCREMENTAL:=0}"

# dl/ is shared across profiles (same downloads); feeds/ + ccache are per-profile
# and set by the wrapper (FEEDS_CACHE / CCACHE_DIR).
DL_CACHE="$BUILD_ROOT/cache/dl"

# --- version helper ----------------------------------------------------------
# Read the op version from a built tree's include/version.mk (VERSION_NUMBER,
# e.g. 25.12-SNAPSHOT) with -SNAPSHOT stripped -> 25.12; once upstream tags a
# real patch level (25.12.1) it flows through. Falls back to REPO_BRANCH
# (openwrt-25.12 -> 25.12) if the tree/line can't be read.
#   derive_op_version <path-to-version.mk>   (echoes the version)
derive_op_version() {
    local vmk="$1" v
    v="$(sed -n 's/^VERSION_NUMBER:=$(if.*,\(.*\))$/\1/p' "$vmk" 2>/dev/null | head -1)"
    v="${v%-SNAPSHOT}"
    [ -n "$v" ] || v="${REPO_BRANCH#openwrt-}"
    printf '%s' "$v"
}

# --- sanity checks -----------------------------------------------------------
# BUILD_ROOT must be a native fs: OpenWrt's tree has huge numbers of small
# parallel writes and hardlinks that corrupt on a virtiofs/macOS bind mount.
check_buildroot_fs() {
    # BUILD_ROOT may live under a root-owned parent (e.g. /opt). Try a plain
    # mkdir first; only if that fails fall back to a one-time sudo mkdir+chown so
    # the tree ends up owned by us and no later step needs privilege.
    if ! mkdir -p "$BUILD_ROOT" 2>/dev/null; then
        echo "INFO: $BUILD_ROOT not writable; creating it once via sudo..." >&2
        sudo mkdir -p "$BUILD_ROOT" \
            && sudo chown "$(id -u):$(id -g)" "$BUILD_ROOT" \
            || { echo "ERROR: failed to create $BUILD_ROOT (sudo needed)." >&2; exit 1; }
    fi
    fstype="$(stat -f -c '%T' "$BUILD_ROOT")"
    case "$fstype" in
        virtiofs|fuseblk|nfs|cifs|9p)
            echo "ERROR: BUILD_ROOT=$BUILD_ROOT is on '$fstype', which corrupts" >&2
            echo "       OpenWrt's parallel small-file writes. Point BUILD_ROOT at" >&2
            echo "       a native ext4/xfs/btrfs volume." >&2
            exit 1
            ;;
    esac
}

check_disk() {
    local avail_kb
    avail_kb="$(df -Pk "$BUILD_ROOT" | awk 'NR==2{print $4}')"
    if [ "$avail_kb" -lt $((20 * 1024 * 1024)) ]; then
        echo "WARN: only $((avail_kb / 1024 / 1024))G free on $BUILD_ROOT; a full" >&2
        echo "      build may need 20-30G. Continuing anyway." >&2
    fi
}

# N1/armvirt hard-require the external Go bootstrap (arm64 can't build Go from
# source); x86 only uses it if present. When missing, auto-install a prebuilt Go
# to $GO_BOOTSTRAP (needs sudo to write under /usr/local; asks once).
: "${GO_BOOTSTRAP_VERSION:=1.24.9}"
check_go_bootstrap() {
    if [ -x "$GO_BOOTSTRAP/bin/go" ]; then
        return 0
    fi
    echo "INFO: Go bootstrap missing at $GO_BOOTSTRAP; installing go$GO_BOOTSTRAP_VERSION via sudo..." >&2
    local arch tarball tmp
    arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    case "$arch" in
        aarch64) arch=arm64 ;;
        x86_64)  arch=amd64 ;;
    esac
    tarball="go${GO_BOOTSTRAP_VERSION}.linux-${arch}.tar.gz"
    tmp="$(mktemp -d)"
    if ! curl -fsSL --proxy "$ALL_PROXY" "https://go.dev/dl/${tarball}" -o "$tmp/$tarball"; then
        echo "ERROR: failed to download https://go.dev/dl/${tarball} via $ALL_PROXY." >&2
        rm -rf "$tmp"; exit 1
    fi
    sudo rm -rf "$GO_BOOTSTRAP" \
        && sudo mkdir -p "$GO_BOOTSTRAP" \
        && sudo tar -C "$GO_BOOTSTRAP" --strip-components=1 -xzf "$tmp/$tarball" \
        || { echo "ERROR: failed to install Go bootstrap to $GO_BOOTSTRAP." >&2; rm -rf "$tmp"; exit 1; }
    rm -rf "$tmp"
    if [ ! -x "$GO_BOOTSTRAP/bin/go" ]; then
        echo "ERROR: Go bootstrap install completed but $GO_BOOTSTRAP/bin/go is missing." >&2
        exit 1
    fi
    echo "INFO: installed $("$GO_BOOTSTRAP/bin/go" version) at $GO_BOOTSTRAP" >&2
}

# Install any missing apt dependencies up front via build-deps.sh (it handles
# sudo + non-interactive apt itself). The list already covers the ophub
# packaging tools; installing before the compile guarantees they're present.
ensure_deps() {
    local deps_script="$SCRIPT_DIR/build-deps.sh" missing="" pkg
    if command -v dpkg-query >/dev/null 2>&1 && [ -f "$deps_script" ]; then
        # shellcheck source=/dev/null
        source "$deps_script"   # sourcing only populates BUILD_DEPS; no install
        for pkg in "${BUILD_DEPS[@]}"; do
            dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" \
                || missing="$missing $pkg"
        done
        if [ -n "$missing" ]; then
            echo "Missing apt packages:$missing"
            echo "Installing via $deps_script ..."
            "$deps_script"
        fi
    fi
}

# Route all outbound fetches (curl/wget, rust/go bootstrap, feeds) through the
# proxy. git does not honour ALL_PROXY for socks, so wire http.proxy explicitly.
setup_proxy() {
    export ALL_PROXY HTTP_PROXY="$ALL_PROXY" HTTPS_PROXY="$ALL_PROXY"
    export http_proxy="$ALL_PROXY" https_proxy="$ALL_PROXY" all_proxy="$ALL_PROXY"
    export NO_PROXY="localhost,127.0.0.1" no_proxy="localhost,127.0.0.1"
    export FORCE_UNSAFE_CONFIGURE=1
    git config --global http.proxy "$ALL_PROXY"
    git config --global https.proxy "$ALL_PROXY"
}

# --- build flow --------------------------------------------------------------
update_feeds() {
    for attempt in 1 2 3; do
        ./scripts/feeds update -a && return 0
        echo "Feed update failed (attempt $attempt/3), retrying..." >&2
        sleep $((attempt * 5))
    done
    echo "Feed update failed after 3 attempts." >&2
    return 1
}

# Re-stamp the shared overlay + profile .config (+ common services) onto the tree
# and regenerate defconfig. Cheap and idempotent, so both full and incremental
# paths run it — an incremental build thus picks up package/overlay edits without
# touching feeds or diy.sh. GO_REQUIRED=1 writes the external Go bootstrap
# unconditionally (N1); otherwise it's written only if a bootstrap is present (x86).
apply_overlay() {
    rm -rf files .config
    cp -r "$COMMON_DIR/files" ./files
    # Profile-specific overlay files (if any) layer on top of the shared set.
    [ -d "$PROFILE_DIR/files" ] && cp -rf "$PROFILE_DIR/files/." ./files/
    cp "$PROFILE_DIR/.config" ./.config
    cat "$COMMON_DIR/config.services" >> .config

    # ccache: reuse cached object files across recompiles. CONFIG_DEVEL=y is the
    # REQUIRED master toggle — in config/Config-devel.in CCACHE ("Use ccache" if
    # DEVEL) and CCACHE_DIR ("if CCACHE") are prompt-gated behind DEVEL, so without
    # it `make defconfig` silently strips CONFIG_CCACHE=y and ccache is never used.
    # Then pin CCACHE_DIR to the persistent per-profile cache via CONFIG_CCACHE_DIR:
    # a bare `export CCACHE_DIR` is NOT enough — rules.mk does `export CCACHE_DIR :=
    # $(TOPDIR)/.ccache`, and a makefile `:=` assignment overrides an inherited env
    # var, so the shell export was ignored and ccache wrote into the (wiped-on-clean-
    # build) tree. rules.mk honours CONFIG_CCACHE_DIR: $(if $(CONFIG_CCACHE_DIR),...).
    export CCACHE_DIR
    cat >> .config <<EOF
CONFIG_DEVEL=y
CONFIG_CCACHE=y
CONFIG_CCACHE_DIR="$CCACHE_DIR"
EOF

    # Bake the build date into VERSION_CODE (%C) so it surfaces in LuCI
    # Status → Overview "固件版本": DISTRIB_DESCRIPTION / OPENWRT_RELEASE = "%D %V %C"
    # → "ImmortalWrt 25.12-SNAPSHOT 2026.08.23 14:30:05". Only touches %C (defaults
    # to the git REVISION otherwise); VERSION_NUMBER is untouched, so derive_op_version
    # / image names are unaffected. TZ inherited from the env (same as imgdate). The
    # space in the date is fine: %C keeps spaces for display (only the %c filename
    # variant transforms them), and VERSION_CODE never enters our image names.
    # CONFIG_VERSIONOPT=y is the master toggle: without it the VERSION_* symbols
    # are gated off and `make defconfig` strips them (verified against ImmortalWrt's
    # official config.buildinfo, which ships CONFIG_VERSIONOPT=y + CONFIG_VERSION_*).
    cat >> .config <<EOF
CONFIG_VERSIONOPT=y
CONFIG_VERSION_CODE="$(date '+%Y.%m.%d %H:%M:%S')"
EOF
    make defconfig

    if [ "${GO_REQUIRED:-0}" = "1" ] || [ -x "$GO_BOOTSTRAP/bin/go" ]; then
        cat >> .config <<EOF
CONFIG_GOLANG_BUILD_BOOTSTRAP=n
CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT="$GO_BOOTSTRAP"
EOF
        make defconfig
    fi
}

# Full or incremental build. Ends with cwd = $OUTDIR/openwrt so callers can
# publish/package from bin/targets. The full path calls the wrapper's run_diy hook.
do_build() {
    mkdir -p "$OUTDIR" "$ARTIFACT_DIR" "$DL_CACHE" "$FEEDS_CACHE" "$CCACHE_DIR"

    # Incremental reuse of a warm tree needs .config present (proof a prior full
    # build got past setup). Fall back to a full build otherwise.
    if [ "$INCREMENTAL" = "1" ] && [ -f "$OUTDIR/openwrt/.config" ]; then
        echo "INCREMENTAL=1: reusing warm tree at $OUTDIR/openwrt (skipping clone/feeds/diy.sh)."
        cd "$OUTDIR/openwrt"
        # Re-point dl/ and feeds/ at the caches in case they went stale.
        [ -L dl ] || { rm -rf dl; ln -s "$DL_CACHE" dl; }
        [ -L feeds ] || { rm -rf feeds; ln -s "$FEEDS_CACHE" feeds; }
        apply_overlay
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
        run_diy
        update_feeds
        ./scripts/feeds install -a

        apply_overlay
    fi

    make download -j"$(( JOBS * 2 ))"
    # dl/ is a symlink to the cache; the trailing slash makes find descend into it.
    find dl/ -size -1k -exec rm -f {} \;
    make -j"$(( JOBS + 1 ))" || make -j1 V=s
}

# Publish bin/targets to $ARTIFACT_DIR (called with cwd = openwrt tree root).
publish_artifacts() {
    if [ -d bin/targets ]; then
        local dest="$ARTIFACT_DIR/bin/targets"
        rm -rf "$dest"
        mkdir -p "$dest"
        cp -a bin/targets/. "$dest/"
        echo "Firmware images copied to $dest"
    else
        echo "No bin/targets directory found; build may have failed." >&2
        exit 1
    fi
}

# Total wall-clock. SECONDS is a bash builtin counting since the wrapper started.
print_build_time() {
    printf 'Total build time: %02dh %02dm %02ds\n' \
        $((SECONDS / 3600)) $(((SECONDS % 3600) / 60)) $((SECONDS % 60))
}
