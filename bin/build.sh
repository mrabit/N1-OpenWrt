#!/usr/bin/env bash
# Native build entry point (no Docker). By default builds ALL three profiles in
# sequence (N1, then x86, then armvirt); pass a profile to build just one:
#
#   bin/build.sh            # build N1, then x86, then armvirt (all)
#   bin/build.sh N1         # Amlogic S905D bypass router only  (-> bin/build-N1.sh)
#   bin/build.sh x86        # x86/64 EFI bypass router only      (-> bin/build-x86.sh)
#   bin/build.sh armvirt    # ARM64 VM (UTM/QEMU) EFI router     (-> bin/build-armvirt.sh)
#   PROFILE=x86 bin/build.sh
#
# Note: each profile is a full 20-30G / full-`make` build, so building all three
# roughly triples time and disk. Each uses its own scratch subtree under
# BUILD_ROOT (build / build-x86 / build-armvirt and per-profile feeds/ccache), so
# they never collide and can share one BUILD_ROOT.
#
# All tunables (BUILD_ROOT, ARTIFACT_DIR, GO_BOOTSTRAP, ALL_PROXY, JOBS,
# REPO_BRANCH, OPHUB_REPO, INCREMENTAL) are read by the profile scripts from the
# environment and pass straight through.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Profile: first positional arg, else $PROFILE, else empty = build all.
PROFILE="${1:-${PROFILE:-}}"

run_profile() {
    case "$1" in
        N1|n1)            "$SCRIPT_DIR/build-N1.sh" ;;
        x86|X86)          "$SCRIPT_DIR/build-x86.sh" ;;
        armvirt|ARMVIRT)  "$SCRIPT_DIR/build-armvirt.sh" ;;
        *)
            echo "ERROR: unknown profile '$1' (expected 'N1', 'x86' or 'armvirt')." >&2
            exit 1
            ;;
    esac
}

if [ -z "$PROFILE" ]; then
    echo "No profile given — building all (N1, then x86, then armvirt)."
    run_profile N1
    run_profile x86
    run_profile armvirt
else
    run_profile "$PROFILE"
fi
