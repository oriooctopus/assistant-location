#!/usr/bin/env ruby
# Adds the standalone "Listen" application target (com.oliverullman.listen) to
# Overland.xcodeproj. Sources live in ListenApp/ (NOT under Modules/, which is a
# synchronized group compiled into Overland). Explicit file references, no
# synced group, so nothing here can leak into the Overland target.
#
# Run via the gen-project workflow, commit the regenerated project.pbxproj.
# Idempotent: exits early when the target is already there.
require "xcodeproj"

TEAM = "J66WVM2DTX"
NAME = "Listen"
APP_ID = "com.oliverullman.listen"
PROFILE = "Listen AdHoc"

proj = Xcodeproj::Project.open("Overland.xcodeproj")
if proj.targets.any? { |t| t.name == NAME }
  puts "#{NAME} target already present"
  exit 0
end

target = proj.new_target(:application, NAME, :ios, "15.0")

group = proj.main_group.find_subpath("ListenApp", true)
group.set_source_tree("SOURCE_ROOT")
sources = Dir["ListenApp/*.m"].sort
headers = Dir["ListenApp/*.h"].sort
abort "no sources in ListenApp/" if sources.empty?
target.add_file_references(sources.map { |f| group.new_file(f) })
(headers + ["ListenApp/Info.plist", "ListenApp/PROTOCOL.md"]).each { |f| group.new_file(f) }

# Same reasoning as add_share_ext.rb: drop the SDK-versioned framework path the
# gem adds; clang module auto-linking (CLANG_ENABLE_MODULES) links
# AVFoundation/MediaPlayer/Speech/WebKit/UIKit from the #imports.
target.frameworks_build_phase.files.to_a.each(&:remove_from_project)

target.build_configurations.each do |c|
  c.build_settings.merge!(
    "PRODUCT_NAME" => "$(TARGET_NAME)",
    "PRODUCT_BUNDLE_IDENTIFIER" => APP_ID,
    "INFOPLIST_FILE" => "ListenApp/Info.plist",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "IPHONEOS_DEPLOYMENT_TARGET" => "15.0",
    "TARGETED_DEVICE_FAMILY" => "1",
    "CLANG_ENABLE_MODULES" => "YES",
    "ENABLE_BITCODE" => "NO",
    # GLLog.h is header-only and shared with Overland.
    "HEADER_SEARCH_PATHS" => ["$(inherited)", "$(SRCROOT)/Shared", "$(SRCROOT)/ListenApp"],
    "CODE_SIGN_STYLE" => "Manual",
    "DEVELOPMENT_TEAM" => TEAM,
    "PROVISIONING_PROFILE_SPECIFIER" => PROFILE,
    "CODE_SIGN_IDENTITY" => "Apple Distribution",
    "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/Frameworks"],
  )
end

proj.save
puts "Added #{NAME} target (#{APP_ID}); blueprint id #{target.uuid}"
