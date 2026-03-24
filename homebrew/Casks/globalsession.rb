cask "globalsession" do
  version "1.0.0"
  sha256 "PLACEHOLDER"

  url "https://github.com/bzantium/globalsession/releases/download/v#{version}/GlobalSession-#{version}.dmg"
  name "GlobalSession"
  desc "macOS menu bar app for monitoring GlobalProtect VPN session status"
  homepage "https://github.com/bzantium/globalsession"

  depends_on macos: ">= :ventura"

  app "GlobalSession.app"

  zap trash: [
    "~/Library/Preferences/com.ryan.GlobalSession.plist",
  ]
end
