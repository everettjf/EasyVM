#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
catalog="$project_root/EZVM/EZVM/Localizable.xcstrings"

ruby -rjson -e '
  catalog = JSON.parse(File.read(ARGV.fetch(0)))
  strings = catalog.fetch("strings")
  format_tokens = /%(?:\d+\$)?(?:lld|llu|ld|lu|[duf@])/ 

  strings.each do |key, entry|
    value = entry.dig("localizations", "zh-Hans", "stringUnit", "value")
    next unless value

    source_tokens = key.scan(format_tokens).map { |token| token.sub(/%\d+\$/, "%") }.sort
    translated_tokens = value.scan(format_tokens).map { |token| token.sub(/%\d+\$/, "%") }.sort
    abort "placeholder mismatch for #{key.inspect}" unless source_tokens == translated_tokens
  end

  required = [
    "Choose USB accessories to attach directly to this virtual machine",
    "Connect %@",
    "Connecting %@…",
    "Disconnect %@",
    "Disconnecting %@…",
    "No approved accessories connected",
    "Wait for the USB connection or disconnection to finish before saving machine state.",
    "Disconnect USB accessories before saving machine state.",
    "This build does not include the Accessory Access entitlement required for USB passthrough.",
    "The running virtual machine no longer has an available USB controller. Restart the virtual machine and try again.",
    "%@ was disconnected from the virtual machine.",
    "Could not connect %@. %@",
    "Could not disconnect %@. It may still be attached, so machine-state saving remains unavailable. %@",
    "Network Adapter %lld",
    "No virtual network adapter",
    "Preparing %@",
    "Recovering %@",
    "%@ suspended while this Mac sleeps",
    "The host did not accept the network attachment. Check the selected interface and try again.",
    "The host disconnected this network adapter. Check the selected interface, VPN, and network access, then reconnect.",
    "macOS 27 First-Boot Provisioning",
    "macOS is applying the first-boot settings for “%@”.",
    "The previous provisioning attempt was interrupted. Sign in as “%@” if the account exists; otherwise choose Retry Next Start. EZVM will not submit it again automatically.",
    "Provisioning for “%@” is ready to retry once. If this VM is running, shut it down; then close this window and run the VM again.",
    "Use macOS Setup Assistant Instead?",
    "Confirm that you can sign in as “%@”. EZVM will permanently remove the temporary provisioning password from this Mac’s Keychain. This cannot be undone.",
    "Could not access guest provisioning credentials in Keychain: %@",
    "The temporary provisioning credential is no longer available.",
    "Virtualization.framework rejected the guest provisioning settings. Review the account details and try again.",
    "Preparing snapshot…",
    "Estimating restore storage…",
    "Preparing restore…",
    "Restoring snapshot \"%@\"…",
    "Snapshot \"%@\" restored",
    "Auditing snapshot integrity…",
    "Snapshot audit cancelled",
    "Inspecting snapshot storage…",
    "Cleaning snapshot storage…",
    "Preparing and checking available space",
    "Copying machine data",
    "Verifying snapshot integrity",
    "Installing the verified transaction",
    "Cancellation requested. EZVM will stop at the next safe boundary.",
    "Protecting snapshot \"%@\"…",
    "Unprotecting snapshot \"%@\"…",
    "Custom VirGL active",
    "Custom VirGL needs attention",
    "Custom VirGL repeatedly failed to present the guest display. The VM is still running; if the display does not recover, stop it and disable Custom VirGL before restarting.",
    "Custom VirGL state cannot be saved.",
    "Apple Virtio is used while installation media is attached so the installer has reliable keyboard and pointer input.",
    "Apple Virtio is used until the EZVM Guest Agent confirms reliable keyboard and pointer input.",
    "The saved session used a graphics configuration that Custom VirGL cannot restore. EZVM discarded it and started the virtual machine normally."
  ]

  required.each do |key|
    unit = strings.dig(key, "localizations", "zh-Hans", "stringUnit")
    abort "missing required USB translation: #{key.inspect}" unless unit&.fetch("state", nil) == "translated"
    abort "empty required USB translation: #{key.inspect}" if unit.fetch("value", "").strip.empty?
  end
' "$catalog"

echo "Verified String Catalog placeholders and core runtime translations."
