# Not published in a tap yet (see README.md in this folder). Update version and sha256 with each release.
cask "sidemoon" do
  version "1.0.0"
  sha256 "1f283ee73df7a75253cd98d3f3ec6ed4a1c8bde2cdab9236e596db64e6747e73"

  url "https://www.sidemoon.app/downloads/Sidemoon-#{version}.dmg"
  name "Sidemoon"
  desc "Floating companion that sends what is on your screen to a Claude Code session"
  homepage "https://www.sidemoon.app/"

  livecheck do
    url "https://www.sidemoon.app/appcast.xml"
    strategy :sparkle
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Sidemoon.app"

  uninstall quit: "app.sidemoon.companion"

  zap trash: [
    "~/.local/bin/sidemoon-claude",
    "~/Library/Application Support/Sidemoon",
    "~/Library/Preferences/app.sidemoon.companion.plist",
  ]

  caveats <<~EOS
    Sidemoon adds hooks to ~/.claude/settings.json when you press Connect in its setup window.
    To remove them, open Setup from the companion's right-click menu and press Disconnect
    before uninstalling. Left behind, they do nothing once the app is gone.
  EOS
end
