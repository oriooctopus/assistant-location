#!/usr/bin/env ruby
# Adds the standalone "Marketplace" application target (com.oliverullman.marketplace)
# to Overland.xcodeproj, modeled on add_quotes_app.rb. App sources live in
# MarketplaceApp/; the page it hosts (Modules/WebPages/questions.html plus the
# page.css and gl-bridge.js it loads) is referenced as bundle resources straight
# from Modules/WebPages/, so the Facebook tab of Overland and this app run one copy.
# No GLManager or other Overland module is pulled in.
#
# Run via the gen-project workflow, commit the regenerated project.pbxproj.
# Idempotent: exits early when the target is already there.
require "xcodeproj"

TEAM = "J66WVM2DTX"
NAME = "Marketplace"
APP_ID = "com.oliverullman.marketplace"
PROFILE = "Marketplace AdHoc"

proj = Xcodeproj::Project.open("Overland.xcodeproj")
if proj.targets.any? { |t| t.name == NAME }
  puts "#{NAME} target already present"
  exit 0
end

target = proj.new_target(:application, NAME, :ios, "15.0")

group = proj.main_group.find_subpath("MarketplaceApp", true)
group.set_source_tree("SOURCE_ROOT")

sources = Dir["MarketplaceApp/*.m"].sort
abort "no sources in MarketplaceApp/" if sources.empty?
target.add_file_references(sources.map { |f| group.new_file(f) })
(Dir["MarketplaceApp/*.h"].sort + ["MarketplaceApp/Info.plist", "MarketplaceApp/Marketplace.entitlements"]).each { |f| group.new_file(f) }

target.resources_build_phase.add_file_reference(group.new_file("MarketplaceApp/Assets.xcassets"), true)
%w[questions.html page.css gl-bridge.js].each do |f|
  target.resources_build_phase.add_file_reference(group.new_file("Modules/WebPages/#{f}"), true)
end

# Same reasoning as add_quotes_app.rb: drop the SDK-versioned framework path the
# gem adds; clang module auto-linking links UIKit/WebKit/UserNotifications.
target.frameworks_build_phase.files.to_a.each(&:remove_from_project)

target.build_configurations.each do |c|
  c.build_settings.merge!(
    "PRODUCT_NAME" => "$(TARGET_NAME)",
    "PRODUCT_BUNDLE_IDENTIFIER" => APP_ID,
    "INFOPLIST_FILE" => "MarketplaceApp/Info.plist",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "IPHONEOS_DEPLOYMENT_TARGET" => "15.0",
    "TARGETED_DEVICE_FAMILY" => "1",
    "CLANG_ENABLE_MODULES" => "YES",
    "ENABLE_BITCODE" => "NO",
    "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
    # BakedConfig.h lives in App/ (CI overwrites it with the real host/token).
    "HEADER_SEARCH_PATHS" => ["$(inherited)", "$(SRCROOT)/App", "$(SRCROOT)/MarketplaceApp"],
    "CODE_SIGN_ENTITLEMENTS" => "MarketplaceApp/Marketplace.entitlements",
    "CODE_SIGN_STYLE" => "Manual",
    "DEVELOPMENT_TEAM" => TEAM,
    "PROVISIONING_PROFILE_SPECIFIER" => PROFILE,
    "CODE_SIGN_IDENTITY" => "Apple Distribution",
    "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/Frameworks"],
  )
end

# MarketplaceOutbox.m is also compiled into SharedTests (add_shared_tests_target.rb, which unit-test.yml runs at CI time).

proj.save
puts "Added #{NAME} target (#{APP_ID}); blueprint id #{target.uuid}"
