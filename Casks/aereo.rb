cask "aereo" do
  version :latest
  sha256 :no_check

  url "https://github.com/Mirzabaig313/Aereo/releases/latest/download/Aereo.dmg"
  name "Aereo"
  desc "Hardware-accelerated live video wallpapers for macOS"
  homepage "https://github.com/Mirzabaig313/Aereo"

  depends_on macos: ">= :sequoia"

  app "Aereo.app"

  zap trash: [
    "~/Library/Application Support/Aereo",
    "~/Library/Caches/com.aereo.app",
    "~/Library/Preferences/com.aereo.app.plist",
  ]
end
