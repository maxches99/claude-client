#!/bin/sh
# Prints the Homebrew cask for one release of the Mac host app. The release workflow commits the output to
# maxches99/homebrew-tap as Casks/claude-remote-host.rb.
#
#   scripts/release/cask.sh <version> <sha256-of-zip>
set -e
VERSION="$1"; SHA="$2"
[ -n "$SHA" ] || { echo "usage: $0 <version> <sha256>" >&2; exit 2; }

cat <<RUBY
cask "claude-remote-host" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/maxches99/claude-client/releases/download/v#{version}/ClaudeRemote-Host.zip"
  name "ClaudeRemote Host"
  desc "Menu-bar host that lets the ClaudeRemote iPhone app drive Claude Code on this Mac"
  homepage "https://github.com/maxches99/claude-client"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "ClaudeRemote Host.app"

  # The build is ad-hoc signed (no Apple developer account), so Gatekeeper would refuse a quarantined copy.
  # Dropping the flag here is what \`brew install --no-quarantine\` would do, without asking the user.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/ClaudeRemote Host.app"],
                   must_succeed: false
  end

  uninstall quit: "dev.maxches.ccremote"

  zap trash: [
    "~/Library/Application Support/ccremote",
    "~/Library/Logs/ccremote.log",
  ]
end
RUBY
