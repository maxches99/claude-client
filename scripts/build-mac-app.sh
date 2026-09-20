#!/bin/sh
# Builds the ClaudeRemote Host menu-bar app into dist/ (plus a zip you can drop on another Mac).
#
#   scripts/build-mac-app.sh            # → dist/ClaudeRemote Host.app + dist/ClaudeRemote-Host.zip
#   scripts/build-mac-app.sh --install  # …and copy it to /Applications and launch it
#
# Signing: ad-hoc by default ("sign to run locally"). For a build that other Macs accept without
# the right-click → Open dance, export TEAM_ID=XXXXXXXXXX (your Apple Developer team) and, if you
# have one, SIGN_IDENTITY="Developer ID Application" — then notarize the zip with `xcrun notarytool`.
#
# Version: MARKETING_VERSION=1.2.3 BUILD_NUMBER=45 override the defaults from the Tuist manifest
# (the release workflow sets them from the git tag and the run number).
set -e
cd "$(dirname "$0")/.."

INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        *) echo "unknown option $arg" >&2; exit 2 ;;
    esac
done

command -v tuist >/dev/null || { echo "tuist is required: brew install tuist" >&2; exit 1; }

APP_NAME="ClaudeRemote Host"
DERIVED=".build/xcode"
DIST="dist"

tuist generate --no-open >/dev/null

VERSION_SETTINGS=""
[ -n "$MARKETING_VERSION" ] && VERSION_SETTINGS="MARKETING_VERSION=$MARKETING_VERSION"
[ -n "$BUILD_NUMBER" ] && VERSION_SETTINGS="$VERSION_SETTINGS CURRENT_PROJECT_VERSION=$BUILD_NUMBER"

SIGNING=""
if [ -n "$TEAM_ID" ]; then
    SIGNING="DEVELOPMENT_TEAM=$TEAM_ID CODE_SIGN_IDENTITY=${SIGN_IDENTITY:-Apple Development} CODE_SIGN_STYLE=Manual"
fi

# Universal binary, so the same zip runs on Apple silicon and Intel Macs.
# shellcheck disable=SC2086
xcodebuild -workspace ClaudeRemote.xcworkspace -scheme ClaudeRemoteHost -configuration Release \
    -derivedDataPath "$DERIVED" -quiet ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO $VERSION_SETTINGS $SIGNING build

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "build did not produce $APP" >&2; exit 1; }

# Only our own outputs go: build-ios-ipa.sh drops its .ipa into the same dist/.
rm -rf "$DIST/$APP_NAME.app" "$DIST/ClaudeRemote-Host.zip"
mkdir -p "$DIST"
cp -R "$APP" "$DIST/"
ditto -c -k --keepParent "$DIST/$APP_NAME.app" "$DIST/ClaudeRemote-Host.zip"
echo "built: $DIST/$APP_NAME.app"
echo "zip:   $DIST/ClaudeRemote-Host.zip  (copy to another Mac, unzip, drag to Applications)"
codesign -dv "$DIST/$APP_NAME.app" 2>&1 | grep -E "^(Authority|Signature|TeamIdentifier)" | sed 's/^/  /' || true

if [ "$INSTALL" = 1 ]; then
    TARGET="/Applications/$APP_NAME.app"
    # Quit a running copy first: replacing a running bundle in place breaks its signature.
    osascript -e "tell application id \"dev.maxches.ccremote\" to quit" >/dev/null 2>&1 || true
    sleep 1
    rm -rf "$TARGET"
    cp -R "$DIST/$APP_NAME.app" "$TARGET"
    open "$TARGET"
    echo "installed and launched $TARGET — look for the phone icon in the menu bar"
fi
