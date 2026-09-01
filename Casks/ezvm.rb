# typed: strict
# frozen_string_literal: true

cask "ezvm" do
  version "1.0.4"
  sha256 "77bff3203756aab11aa512715a53839036360f40c420f328d7b435857a749925"

  url "https://github.com/everettjf/ezvm/releases/download/v#{version}/EZVM-#{version}.zip?notarized=1"
  name "EZVM"
  desc "Simple native virtual machines for Apple silicon Macs"
  homepage "https://xnu.app/ezvm"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "EZVM.app"
  binary "#{appdir}/EZVM.app/Contents/Helpers/ezvm"

  zap trash: [
    "~/Library/Application Support/EZVM",
    "~/Library/Preferences/com.everettjf.ezvm.plist",
    "~/Library/Saved Application State/com.everettjf.ezvm.savedState",
  ]
end
