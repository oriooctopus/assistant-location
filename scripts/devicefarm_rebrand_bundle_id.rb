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
require "xcodeproj"

proj = Xcodeproj::Project.open("Overland.xcodeproj")
app = proj.targets.find { |t| t.name == "Overland" } or abort "no Overland target"

app.build_configurations.each do |c|
  c.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.oliverullman.assistantlocation.devicefarm"
end

proj.save
puts "Overland target bundle id overridden to com.oliverullman.assistantlocation.devicefarm for this build"
