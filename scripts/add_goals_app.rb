#!/usr/bin/env ruby
# Adds the standalone "Goals" application target (com.oliverullman.goals) to
# Overland.xcodeproj, modeled on add_gripes_app.rb. It is a full-screen
# WKWebView wrapper of the hosted Goals web app: no bundled page, no push, no
# BakedConfig. Sources live in GoalsApp/.
#
# Run via the gen-project workflow, commit the regenerated project.pbxproj.
# Idempotent: exits early when the target is already there.
require "xcodeproj"

TEAM = "J66WVM2DTX"
NAME = "Goals"
APP_ID = "com.oliverullman.goals"
PROFILE = "Goals AppStore"

proj = Xcodeproj::Project.open("Overland.xcodeproj")
if proj.targets.any? { |t| t.name == NAME }
  puts "#{NAME} target already present"
  exit 0
end

target = proj.new_target(:application, NAME, :ios, "15.0")

group = proj.main_group.find_subpath("GoalsApp", true)
group.set_source_tree("SOURCE_ROOT")

sources = Dir["GoalsApp/*.m"].sort
abort "no sources in GoalsApp/" if sources.empty?
target.add_file_references(sources.map { |f| group.new_file(f) })
(Dir["GoalsApp/*.h"].sort + ["GoalsApp/Info.plist"]).each { |f| group.new_file(f) }

target.resources_build_phase.add_file_reference(group.new_file("GoalsApp/Assets.xcassets"), true)

# Drop the SDK-versioned framework path the gem adds; clang module
# auto-linking links UIKit/WebKit.
target.frameworks_build_phase.files.to_a.each(&:remove_from_project)

target.build_configurations.each do |c|
  c.build_settings.merge!(
    "PRODUCT_NAME" => "$(TARGET_NAME)",
    "PRODUCT_BUNDLE_IDENTIFIER" => APP_ID,
    "INFOPLIST_FILE" => "GoalsApp/Info.plist",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "IPHONEOS_DEPLOYMENT_TARGET" => "15.0",
    "TARGETED_DEVICE_FAMILY" => "1",
    "CLANG_ENABLE_MODULES" => "YES",
    "ENABLE_BITCODE" => "NO",
    "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
    "HEADER_SEARCH_PATHS" => ["$(inherited)", "$(SRCROOT)/GoalsApp"],
    "CODE_SIGN_STYLE" => "Manual",
    "DEVELOPMENT_TEAM" => TEAM,
    "PROVISIONING_PROFILE_SPECIFIER" => PROFILE,
    "CODE_SIGN_IDENTITY" => "Apple Distribution",
    "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/Frameworks"],
  )
end

proj.save
puts "Added #{NAME} target (#{APP_ID}); blueprint id #{target.uuid}"
