#!/usr/bin/env ruby
# Adds the standalone "Cycle" application target (com.oliverullman.cycle) to
# Overland.xcodeproj, modeled on add_gripes_app.rb. App sources live in
# CycleApp/; the page it hosts is the CycleApp/web folder, added as a folder
# reference so every file placed there (including the build-time config.js) is
# bundled with no project change. No push entitlement, no GLManager, no BakedConfig.
#
# Run via the gen-project workflow, commit the regenerated project.pbxproj.
# Idempotent: exits early when the target is already there.
require "xcodeproj"

TEAM = "J66WVM2DTX"
NAME = "Cycle"
APP_ID = "com.oliverullman.cycle"
PROFILE = "Cycle AdHoc"

proj = Xcodeproj::Project.open("Overland.xcodeproj")
if proj.targets.any? { |t| t.name == NAME }
  puts "#{NAME} target already present"
  exit 0
end

target = proj.new_target(:application, NAME, :ios, "15.0")

group = proj.main_group.find_subpath("CycleApp", true)
group.set_source_tree("SOURCE_ROOT")

sources = Dir["CycleApp/*.m"].sort
abort "no sources in CycleApp/" if sources.empty?
target.add_file_references(sources.map { |f| group.new_file(f) })
(Dir["CycleApp/*.h"].sort + ["CycleApp/Info.plist"]).each { |f| group.new_file(f) }

target.resources_build_phase.add_file_reference(group.new_file("CycleApp/Assets.xcassets"), true)
# Folder reference: the directory is copied into the bundle as `web/`.
web = group.new_reference("CycleApp/web")
web.last_known_file_type = "folder"
web.explicit_file_type = nil
target.resources_build_phase.add_file_reference(web, true)

# Same reasoning as add_quotes_app.rb: drop the SDK-versioned framework path the
# gem adds; clang module auto-linking links UIKit/WebKit/UserNotifications.
target.frameworks_build_phase.files.to_a.each(&:remove_from_project)

target.build_configurations.each do |c|
  c.build_settings.merge!(
    "PRODUCT_NAME" => "$(TARGET_NAME)",
    "PRODUCT_BUNDLE_IDENTIFIER" => APP_ID,
    "INFOPLIST_FILE" => "CycleApp/Info.plist",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "IPHONEOS_DEPLOYMENT_TARGET" => "15.0",
    "TARGETED_DEVICE_FAMILY" => "1",
    "CLANG_ENABLE_MODULES" => "YES",
    "ENABLE_BITCODE" => "NO",
    "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
    "HEADER_SEARCH_PATHS" => ["$(inherited)", "$(SRCROOT)/CycleApp"],
    "CODE_SIGN_STYLE" => "Manual",
    "DEVELOPMENT_TEAM" => TEAM,
    "PROVISIONING_PROFILE_SPECIFIER" => PROFILE,
    "CODE_SIGN_IDENTITY" => "Apple Distribution",
    "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/Frameworks"],
  )
end

proj.save
puts "Added #{NAME} target (#{APP_ID}); blueprint id #{target.uuid}"
