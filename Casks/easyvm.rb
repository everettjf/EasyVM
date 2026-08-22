# typed: strict
# frozen_string_literal: true

cask "easyvm" do
  version "3.0.1"
  sha256 :no_check

  url "https://github.com/everettjf/easyvm/releases/download/v#{version}/EasyVM-#{version}.zip?notarized=1"
  name "EasyVM"
  desc "Simple native virtual machines for Apple silicon Macs"
  homepage "https://xnu.app/easyvm"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  # macOS 27 beta can leave notarized Virtualization.framework apps suspended
  # in dyld when Homebrew propagates archive security metadata to the app.
  preflight do
    %w[com.apple.quarantine com.apple.provenance].each do |attribute|
      system_command "/usr/bin/xattr",
                     args: ["-dr", attribute, staged_path/"EasyVM.app"]
    end
  end

  app "EasyVM.app"

  zap trash: [
    "~/Library/Application Support/EasyVM",
    "~/Library/Preferences/com.everettjf.easyvm.plist",
    "~/Library/Saved Application State/com.everettjf.easyvm.savedState",
  ]
end
