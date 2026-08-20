#!/usr/bin/env bash
# Native build entry point (no Docker). By default builds BOTH profiles in
# sequence (N1 then x86); pass a profile to build just one:
#
#   bin/build.sh            # build N1 then x86 (both)
#   bin/build.sh N1         # Amlogic S905D bypass router only (-> bin/build-N1.sh)
#   bin/build.sh x86        # x86/64 EFI bypass router only  (-> bin/build-x86.sh)
#   PROFILE=x86 bin/build.sh
#
# Note: each profile is a full 20-30G / full-`make` build, so building both
# roughly doubles time and disk. x86 uses its own scratch subtree under
# BUILD_ROOT (build-x86 / cache/feeds-x86 / cache/ccache-x86), so the two never
# collide and can share one BUILD_ROOT.
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
        N1|n1)   "$SCRIPT_DIR/build-N1.sh" ;;
        x86|X86) "$SCRIPT_DIR/build-x86.sh" ;;
        *)
            echo "ERROR: unknown profile '$1' (expected 'N1' or 'x86')." >&2
            exit 1
            ;;
    esac
}

if [ -z "$PROFILE" ]; then
    echo "No profile given — building both (N1, then x86)."
    run_profile N1
    run_profile x86
else
    run_profile "$PROFILE"
fi
