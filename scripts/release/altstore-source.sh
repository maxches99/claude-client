#!/bin/sh
# Writes the AltStore / SideStore source JSON for one release.
#
#   scripts/release/altstore-source.sh <version> <build> <ipa> <download-url> [<notes-file>] > dist/altstore.json
#
# Add https://github.com/maxches99/claude-client/releases/latest/download/altstore.json as a source in
# AltStore or SideStore: it always redirects to the newest release, so the phone sees updates by itself.
set -e
cd "$(dirname "$0")/../.."

VERSION="$1"; BUILD="$2"; IPA="$3"; URL="$4"; NOTES="${5:-}"
[ -n "$URL" ] || { echo "usage: $0 <version> <build> <ipa> <download-url> [<notes-file>]" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required: brew install jq" >&2; exit 1; }

REPO="https://github.com/maxches99/claude-client"
ICON="https://raw.githubusercontent.com/maxches99/claude-client/main/ClaudeRemoteHost/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"
SIZE=$(stat -f %z "$IPA" 2>/dev/null || stat -c %s "$IPA")
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [ -n "$NOTES" ] && [ -s "$NOTES" ]; then
    RELEASE_NOTES=$(cat "$NOTES")
else
    RELEASE_NOTES="See $REPO/releases/tag/v$VERSION"
fi
# The privacy prompts the app can show, straight from its Info.plist.
PRIVACY=$(plutil -convert json -o - ClaudeRemote/Info.plist | jq 'with_entries(select(.key | test("UsageDescription$")))')
ENTITLEMENTS=$(plutil -convert json -o - ClaudeRemote/ClaudeRemote.entitlements | jq 'keys')

jq -n \
    --arg version "$VERSION" --arg build "$BUILD" --arg url "$URL" --arg date "$DATE" \
    --argjson size "$SIZE" --arg notes "$RELEASE_NOTES" --arg repo "$REPO" --arg icon "$ICON" \
    --argjson privacy "$PRIVACY" --argjson entitlements "$ENTITLEMENTS" '{
    name: "ClaudeRemote",
    identifier: "dev.maxches.claude-client",
    subtitle: "Claude Code on your Mac, from your phone",
    description: "Drive Claude Code and Codex sessions running on your Mac from an iPhone or iPad. Pairs with the ClaudeRemote Host menu-bar app.",
    iconURL: $icon,
    website: $repo,
    tintColor: "#D97757",
    apps: [{
        name: "ClaudeRemote",
        bundleIdentifier: "dev.maxches.ClaudeRemote",
        developerName: "Max Chesnikov",
        subtitle: "Claude Code on your Mac, from your phone",
        localizedDescription: "Watch and steer Claude Code sessions on your Mac: approve tool calls, answer questions, send prompts, read diffs, browse the project, watch the iOS Simulator — over Wi-Fi or through the relay when you are away.\n\nNeeds the ClaudeRemote Host app on the Mac (brew install --cask maxches99/tap/claude-remote-host).",
        iconURL: $icon,
        tintColor: "#D97757",
        category: "developer",
        screenshotURLs: [],
        versions: [{
            version: $version,
            buildVersion: $build,
            date: $date,
            localizedDescription: $notes,
            downloadURL: $url,
            size: $size,
            minOSVersion: "17.0"
        }],
        appPermissions: {
            entitlements: $entitlements,
            privacy: $privacy
        }
    }],
    news: []
}'
