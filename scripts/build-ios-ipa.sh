#!/bin/sh
# Builds an unsigned ClaudeRemote.ipa into dist/ for sideloading (AltStore, SideStore, Sideloadly):
# those tools re-sign the app with the user's own Apple ID, so no developer account is needed here.
#
#   scripts/build-ios-ipa.sh                       # → dist/ClaudeRemote.ipa
#   STRIP_EXTENSIONS=1 scripts/build-ios-ipa.sh    # → dist/ClaudeRemote-no-widget.ipa (no widget, so no App
#                                                  #   Group, which a free Apple ID can't create; the share
#                                                  #   extension stays — it needs none)
#
# The Watch app is always left out: sideloaders can't install watchOS apps, and a free Personal Team
# gets only 10 App IDs a week (each embedded app / extension is one). Entitlements are re-applied with
# an ad-hoc signature so the sideloader sees the App Group and asks for it when it signs.
#
# Version: MARKETING_VERSION=1.2.3 BUILD_NUMBER=45 override the defaults from the Tuist manifest.
set -e
cd "$(dirname "$0")/.."

command -v tuist >/dev/null || { echo "tuist is required: brew install tuist" >&2; exit 1; }

APP_NAME="ClaudeRemote"
IPA_NAME="ClaudeRemote"
[ "${STRIP_EXTENSIONS:-0}" = 1 ] && IPA_NAME="ClaudeRemote-no-widget"
DERIVED=".build/xcode"
DIST="dist"
STAGE="$DERIVED/ipa"

tuist generate --no-open >/dev/null

VERSION_SETTINGS=""
[ -n "$MARKETING_VERSION" ] && VERSION_SETTINGS="MARKETING_VERSION=$MARKETING_VERSION"
[ -n "$BUILD_NUMBER" ] && VERSION_SETTINGS="$VERSION_SETTINGS CURRENT_PROJECT_VERSION=$BUILD_NUMBER"

# shellcheck disable=SC2086
xcodebuild -workspace ClaudeRemote.xcworkspace -scheme "$APP_NAME" -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" -quiet \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO $VERSION_SETTINGS build

APP="$DERIVED/Build/Products/Release-iphoneos/$APP_NAME.app"
[ -d "$APP" ] || { echo "build did not produce $APP" >&2; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
STAGED="$STAGE/Payload/$APP_NAME.app"

rm -rf "$STAGED/Watch"
if [ "${STRIP_EXTENSIONS:-0}" = 1 ]; then
    # Only the widget needs the App Group a free Apple ID can't sign; the share extension stays.
    rm -rf "$STAGED/PlugIns/ClaudeRemoteWidget.appex"
fi

# Ad-hoc sign inside-out so the entitlements travel with the bundle (the sideloader replaces the
# signature itself, but reads the entitlements it finds here).
if [ -d "$STAGED/PlugIns/ClaudeRemoteShare.appex" ]; then
    codesign --force --sign - "$STAGED/PlugIns/ClaudeRemoteShare.appex"
fi
if [ -d "$STAGED/PlugIns/ClaudeRemoteWidget.appex" ]; then
    codesign --force --sign - --entitlements ClaudeRemote/ClaudeRemoteWidget/ClaudeRemoteWidget.entitlements \
        "$STAGED/PlugIns/ClaudeRemoteWidget.appex"
fi
if [ "${STRIP_EXTENSIONS:-0}" = 1 ]; then
    # Nothing left to share a container with, and a free Apple ID can't create the group anyway.
    codesign --force --sign - "$STAGED"
else
    codesign --force --sign - --entitlements ClaudeRemote/ClaudeRemote.entitlements "$STAGED"
fi

mkdir -p "$DIST"
rm -f "$DIST/$IPA_NAME.ipa"
(cd "$STAGE" && ditto -c -k --keepParent --norsrc --noextattr Payload "$OLDPWD/$DIST/$IPA_NAME.ipa")
echo "ipa:   $DIST/$IPA_NAME.ipa  ($(du -h "$DIST/$IPA_NAME.ipa" | cut -f1))"
echo "       version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGED/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$STAGED/Info.plist"))"
