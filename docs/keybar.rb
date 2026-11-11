# The Homebrew cask, for RossNicholson/homebrew-tap (Casks/keybar.rb). Copy it
# there for the first release; after that, CI bumps the version and sha256.
cask "keybar" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/RossNicholson/keybar/releases/download/v#{version}/KeyBar-#{version}.dmg"
  name "KeyBar"
  desc "Menu bar app keeping API keys in the Keychain for Claude Code, via an MCP server"
  homepage "https://github.com/RossNicholson/keybar"

  depends_on macos: :sonoma

  app "KeyBar.app"
  # The MCP server Claude Code runs, also handy for `claude mcp add` by hand
  binary "#{appdir}/KeyBar.app/Contents/Helpers/keybar"

  uninstall quit: "com.rossnicholson.KeyBar"

  # Key values stay in the login keychain (items named "KeyBar: NAME"); use
  # Settings → Delete everything in the app first to remove them too
  zap trash: [
    "~/.keybar",
    "~/Library/Caches/com.rossnicholson.KeyBar",
    "~/Library/HTTPStorages/com.rossnicholson.KeyBar",
    "~/Library/Preferences/com.rossnicholson.KeyBar.plist",
  ]
end
