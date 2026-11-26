# Not published in a tap yet (see README.md in this folder). Update version and sha256 with each release.
cask "sidemoon" do
  version "1.0.7"
  sha256 "88fd8cd6ca5e8d64b4d2d88d452123da5be1c11c0e61a0bff9a30f4134cbddcf"

  url "https://github.com/EdonZo/sidemoon/releases/download/v#{version}/Sidemoon-#{version}.dmg",
      verified: "github.com/EdonZo/sidemoon/"
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
