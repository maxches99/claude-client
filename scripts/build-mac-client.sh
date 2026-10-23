#!/bin/sh
# Builds the native ClaudeRemote Mac client into dist/ (plus a zip you can drop on another Mac).
#
#   scripts/build-mac-client.sh            # → dist/ClaudeRemote.app + dist/ClaudeRemote-Mac.zip
#   scripts/build-mac-client.sh --install  # …and copy it to /Applications and launch it
#
# Signing and versions work as in scripts/build-mac-app.sh (TEAM_ID / SIGN_IDENTITY, MARKETING_VERSION /
# BUILD_NUMBER, otherwise the newest v* tag).
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

APP_NAME="ClaudeRemote"
DERIVED=".build/xcode"
DIST="dist"

tuist generate --no-open >/dev/null

[ -z "$MARKETING_VERSION" ] && MARKETING_VERSION=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//')
VERSION_SETTINGS=""
[ -n "$MARKETING_VERSION" ] && VERSION_SETTINGS="MARKETING_VERSION=$MARKETING_VERSION"
[ -n "$BUILD_NUMBER" ] && VERSION_SETTINGS="$VERSION_SETTINGS CURRENT_PROJECT_VERSION=$BUILD_NUMBER"

SIGNING=""
if [ -n "$TEAM_ID" ]; then
    SIGNING="DEVELOPMENT_TEAM=$TEAM_ID CODE_SIGN_IDENTITY=${SIGN_IDENTITY:-Apple Development} CODE_SIGN_STYLE=Manual"
fi

# shellcheck disable=SC2086
xcodebuild -workspace ClaudeRemote.xcworkspace -scheme ClaudeRemoteMac -configuration Release \
    -derivedDataPath "$DERIVED" -quiet ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO $VERSION_SETTINGS $SIGNING build

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "build did not produce $APP" >&2; exit 1; }

rm -rf "$DIST/$APP_NAME.app" "$DIST/ClaudeRemote-Mac.zip"
mkdir -p "$DIST"
cp -R "$APP" "$DIST/"
ditto -c -k --keepParent "$DIST/$APP_NAME.app" "$DIST/ClaudeRemote-Mac.zip"
echo "built: $DIST/$APP_NAME.app"
echo "zip:   $DIST/ClaudeRemote-Mac.zip  (copy to another Mac, unzip, drag to Applications)"
codesign -dv "$DIST/$APP_NAME.app" 2>&1 | grep -E "^(Authority|Signature|TeamIdentifier)" | sed 's/^/  /' || true

if [ "$INSTALL" = 1 ]; then
    TARGET="/Applications/$APP_NAME.app"
    osascript -e "tell application id \"dev.maxches.ClaudeRemote.mac\" to quit" >/dev/null 2>&1 || true
    sleep 1
    rm -rf "$TARGET"
    cp -R "$DIST/$APP_NAME.app" "$TARGET"
    open "$TARGET"
    echo "installed and launched $TARGET"
fi
