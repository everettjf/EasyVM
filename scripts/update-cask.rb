#!/usr/bin/env ruby

require "digest"

version, archive_path, template_path, output_path = ARGV
abort "usage: update-cask.rb <version> <archive> <template> <output>" unless output_path

version = version.delete_prefix("v")
sha256 = Digest::SHA256.file(archive_path).hexdigest
content = File.read(template_path)
content.sub!(/version "[^"]+"/, %(version "#{version}"))
content.sub!(/sha256 (?:"[^"]+"|:no_check)/, %(sha256 "#{sha256}"))
File.write(output_path, content)
puts "Updated #{output_path} to EZVM #{version} (#{sha256})"
