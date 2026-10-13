#!/usr/bin/env ruby
# Adds the standalone "Gripes" application target (com.oliverullman.gripes) to
# Overland.xcodeproj, modeled on add_marketplace_app.rb. App sources live in
# GripesApp/; the page it hosts is bundled (GripesApp/web/*) together with the
# shared theme files page.css and gl-bridge.js straight from Modules/WebPages/,
# so the app works with no network. No push entitlement, no GLManager.
#
# Run via the gen-project workflow, commit the regenerated project.pbxproj.
# Idempotent: exits early when the target is already there.
require "xcodeproj"

TEAM = "J66WVM2DTX"
NAME = "Gripes"
APP_ID = "com.oliverullman.gripes"
PROFILE = "Gripes AdHoc"

proj = Xcodeproj::Project.open("Overland.xcodeproj")
if proj.targets.any? { |t| t.name == NAME }
  puts "#{NAME} target already present"
  exit 0
end

target = proj.new_target(:application, NAME, :ios, "15.0")

group = proj.main_group.find_subpath("GripesApp", true)
group.set_source_tree("SOURCE_ROOT")

sources = Dir["GripesApp/*.m"].sort
abort "no sources in GripesApp/" if sources.empty?
target.add_file_references(sources.map { |f| group.new_file(f) })
(Dir["GripesApp/*.h"].sort + ["GripesApp/Info.plist"]).each { |f| group.new_file(f) }

target.resources_build_phase.add_file_reference(group.new_file("GripesApp/Assets.xcassets"), true)
# Bundle resources are flattened into the app root, so the names must be unique.
web = %w[gripes.html gripes.css gripes-core.js gripes-ui.js].map { |f| "GripesApp/web/#{f}" } +
      %w[page.css gl-bridge.js].map { |f| "Modules/WebPages/#{f}" }
web.each { |f| target.resources_build_phase.add_file_reference(group.new_file(f), true) }

# Same reasoning as add_quotes_app.rb: drop the SDK-versioned framework path the
# gem adds; clang module auto-linking links UIKit/WebKit/Speech/AVFoundation.
target.frameworks_build_phase.files.to_a.each(&:remove_from_project)

target.build_configurations.each do |c|
  c.build_settings.merge!(
    "PRODUCT_NAME" => "$(TARGET_NAME)",
    "PRODUCT_BUNDLE_IDENTIFIER" => APP_ID,
    "INFOPLIST_FILE" => "GripesApp/Info.plist",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "IPHONEOS_DEPLOYMENT_TARGET" => "15.0",
    "TARGETED_DEVICE_FAMILY" => "1",
    "CLANG_ENABLE_MODULES" => "YES",
    "ENABLE_BITCODE" => "NO",
    "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
    # BakedConfig.h lives in App/ (CI overwrites it with the real host/token).
    "HEADER_SEARCH_PATHS" => ["$(inherited)", "$(SRCROOT)/App", "$(SRCROOT)/GripesApp"],
    "CODE_SIGN_STYLE" => "Manual",
    "DEVELOPMENT_TEAM" => TEAM,
    "PROVISIONING_PROFILE_SPECIFIER" => PROFILE,
    "CODE_SIGN_IDENTITY" => "Apple Distribution",
    "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/Frameworks"],
  )
end

proj.save
puts "Added #{NAME} target (#{APP_ID}); blueprint id #{target.uuid}"
