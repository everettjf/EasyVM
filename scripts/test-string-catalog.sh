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
    "Could not disconnect %@. It may still be attached, so machine-state saving remains unavailable. %@"
  ]

  required.each do |key|
    unit = strings.dig(key, "localizations", "zh-Hans", "stringUnit")
    abort "missing required USB translation: #{key.inspect}" unless unit&.fetch("state", nil) == "translated"
    abort "empty required USB translation: #{key.inspect}" if unit.fetch("value", "").strip.empty?
  end
' "$catalog"

echo "Verified String Catalog placeholders and core USB translations."
