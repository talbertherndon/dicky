#!/usr/bin/env bash
# Single-command release pipeline for OpenClicky (direct distribution,
# NOT App Store):
#   1. bump-version.sh       -> updates MARKETING_VERSION + build number
#   2. release.sh            -> archive, Developer ID sign, DMG, notarize, staple
#   3. generate-appcast.sh   -> Sparkle EdDSA signature + appcast.xml
#   4. summary of what to commit/tag/upload (you do the actual push)
#
# Usage:
#   scripts/ship.sh                          # uses current project version
#   scripts/ship.sh 1.1.0                    # bump marketing to 1.1.0, auto build++
#   scripts/ship.sh 1.1.0 7                  # bump marketing to 1.1.0, build to 7
#   scripts/ship.sh 1.1.0 7 --skip-notarize  # smoke-test the pipeline
#   scripts/ship.sh --no-bump                # skip bump, build whatever's in project

set -euo pipefail

cd "$(dirname "$0")/.."

NO_BUMP=0
SKIP_NOTARIZE=0
MARKETING=""
BUILD=""

for arg in "$@"; do
    case "$arg" in
        --no-bump) NO_BUMP=1 ;;
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        --help|-h)
            sed -n '2,18p' "$0"
            exit 0
            ;;
        *)
            if [[ -z "$MARKETING" ]]; then
                MARKETING="$arg"
            elif [[ -z "$BUILD" ]]; then
                BUILD="$arg"
            fi
            ;;
    esac
done

if [[ $NO_BUMP -eq 0 && -z "$MARKETING" ]]; then
    echo "ERROR: pass a marketing version (or use --no-bump)." >&2
    echo "  scripts/ship.sh 1.1.0           # bump to 1.1.0, auto-increment build" >&2
    echo "  scripts/ship.sh 1.1.0 7         # bump to 1.1.0, build 7" >&2
    echo "  scripts/ship.sh --no-bump       # build current project version" >&2
    exit 64
fi

# --- Sanity: working tree clean (warn, don't block) -----------------------
if ! git diff --quiet HEAD 2>/dev/null; then
    echo "WARNING: working tree has uncommitted changes. They will be baked into the build." >&2
    echo "         Press Ctrl-C to abort, or wait 3 seconds to continue..." >&2
    sleep 3
fi

# --- Step 1: bump ----------------------------------------------------------
if [[ $NO_BUMP -eq 0 ]]; then
    echo "==> Step 1/3: bumping version"
    if [[ -n "$BUILD" ]]; then
        scripts/bump-version.sh "$MARKETING" "$BUILD"
    else
        scripts/bump-version.sh "$MARKETING"
    fi
else
    echo "==> Step 1/3: skipped (--no-bump)"
    scripts/bump-version.sh --show
fi

# Refresh values for downstream steps.
PROJECT="leanring-buddy.xcodeproj/project.pbxproj"
FINAL_VERSION=$(grep -m1 "MARKETING_VERSION" "$PROJECT" | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/' | tr -d ' ')
FINAL_BUILD=$(xcrun agvtool what-version -terse 2>/dev/null | tail -1 | tr -d ' ')

# --- Step 2: build/sign/notarize ------------------------------------------
echo ""
echo "==> Step 2/3: archive + sign + notarize"
if [[ $SKIP_NOTARIZE -eq 1 ]]; then
    scripts/release.sh "$FINAL_VERSION" "$FINAL_BUILD" --skip-notarize
else
    scripts/release.sh "$FINAL_VERSION" "$FINAL_BUILD"
fi

DMG_PATH="dist/OpenClicky-${FINAL_VERSION}-${FINAL_BUILD}.dmg"
if [[ ! -f "$DMG_PATH" ]]; then
    echo "ERROR: release.sh did not produce expected DMG at $DMG_PATH" >&2
    exit 1
fi

# --- Step 3: appcast -------------------------------------------------------
echo ""
echo "==> Step 3/3: Sparkle appcast"
scripts/generate-appcast.sh "$DMG_PATH"

echo ""
echo "================================================================"
echo "  Release ${FINAL_VERSION} (build ${FINAL_BUILD}) ready."
echo "================================================================"
echo ""
echo "  DMG:      ${DMG_PATH}"
echo "  Appcast:  appcast.xml"
echo ""
echo "Remaining manual steps:"
echo "  1. Create the GitHub release:"
echo "       gh release create v${FINAL_VERSION} ${DMG_PATH} \\"
echo "         --title \"OpenClicky ${FINAL_VERSION}\" \\"
echo "         --notes \"Release notes here\""
echo ""
echo "  2. Commit + tag + push:"
echo "       git add appcast.xml leanring-buddy.xcodeproj/project.pbxproj"
echo "       git commit -m \"Release ${FINAL_VERSION} (build ${FINAL_BUILD})\""
echo "       git tag v${FINAL_VERSION}"
echo "       git push && git push --tags"
echo ""
echo "  Sparkle SUFeedURL points at the appcast on the main branch, so"
echo "  shipping the appcast.xml commit is what triggers OTA updates."
