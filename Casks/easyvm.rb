# typed: strict
# frozen_string_literal: true

cask "easyvm" do
  version "3.0.1"
  sha256 :no_check

  url "https://github.com/everettjf/easyvm/releases/download/v#{version}/EasyVM-#{version}.zip"
  name "EasyVM"
  desc "Simple native virtual machines for Apple silicon Macs"
  homepage "https://everettjf.github.io/easyvm/"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "EasyVM.app"

  zap trash: [
    "~/Library/Application Support/EasyVM",
    "~/Library/Preferences/com.everettjf.easyvm.plist",
    "~/Library/Saved Application State/com.everettjf.easyvm.savedState",
  ]
end
