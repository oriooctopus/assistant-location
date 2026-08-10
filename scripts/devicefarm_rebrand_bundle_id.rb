#!/usr/bin/env ruby
# Overrides the "Overland" target's PRODUCT_BUNDLE_IDENTIFIER for the Device
# Farm CI build only (this is an ephemeral checkout — never committed back).
#
# com.oliverullman.assistantlocation (the real bundle ID, used by
# build.yml/ota.yml) has SIRIKIT and ACCESS_WIFI_INFORMATION permanently
# registered as capabilities on its App ID in App Store Connect. Automatic
# signing re-syncs whatever's registered there into every provisioning
# profile it generates for that bundle ID, regardless of what
# Overland.entitlements locally contains — confirmed by two failed attempts
# to strip the entitlement locally (command-line CODE_SIGN_ENTITLEMENTS
# override, then overwriting the file in-place) that had zero effect on the
# built IPA. AWS Device Farm's resigner can't handle the Siri entitlement
# and fails every scheduled run instantly ("Signing error with app or
# tests... at our end"), confirmed via an isolation test running AWS's own
# known-good sample app through the same AWS account (it resigned fine).
#
# A dedicated bundle ID that's never had Siri registered sidesteps this
# without touching the real App ID's capabilities (which the shipped app
# actually needs for Siri Shortcuts).
# Renaming Overland's bundle ID alone isn't enough: Apple validates at BUILD
# time (not just App Store submission) that every embedded extension's
# bundle ID is prefixed by its parent app's — confirmed by a real build
# failure ("Embedded binary's bundle identifier is not prefixed with the
# parent app's bundle identifier") once JournalControl/ShareToDesktop's
# still-old-prefixed IDs no longer matched the renamed parent. Since Device
# Farm doesn't need those extensions at all (already stripped from app.ipa
# in the "Package IPAs" step, and XCTest can't drive them out-of-process
# anyway), removing their embed dependency from Overland entirely for this
# build sidesteps needing to rename + re-register two more App IDs.
require "xcodeproj"

proj = Xcodeproj::Project.open("Overland.xcodeproj")
app = proj.targets.find { |t| t.name == "Overland" } or abort "no Overland target"

app.build_configurations.each do |c|
  c.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.oliverullman.assistantlocation.devicefarm"
end

EXTENSION_NAMES = ["JournalControl", "ShareToDesktop"]

app.dependencies.select { |d| d.target && EXTENSION_NAMES.include?(d.target.name) }.each do |dep|
  puts "Removing target dependency: #{dep.target.name}"
  dep.remove_from_project
end

app.build_phases.grep(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase).each do |phase|
  removed = phase.files.select { |bf| bf.file_ref && EXTENSION_NAMES.any? { |n| bf.file_ref.path.to_s.include?(n) } }
  removed.each do |bf|
    puts "Removing embed reference: #{bf.file_ref.path}"
    phase.remove_build_file(bf)
  end
end

proj.save
puts "Overland target bundle id overridden to com.oliverullman.assistantlocation.devicefarm, extension embeds removed, for this build"
