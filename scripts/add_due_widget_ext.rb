#!/usr/bin/env ruby
# Adds the "DueWidget" extension (com.oliverullman.due.widget: lock-screen Control + accessoryCircular widget that open
# Due on the New Reminder sheet) to Overland.xcodeproj and embeds it in the Due app. Mirrors add_journal_control_ext.rb.
# DueComposeIntent.swift is compiled into BOTH the extension and the Due app (see its header for why). No entitlements:
# the extension has no App Group or keychain use. The Due scheme builds the extension through the app's target dependency.
# Run via the gen-project workflow (the dev box has no ruby), then commit the regenerated project.pbxproj. Idempotent.
require "xcodeproj"

TEAM = "J66WVM2DTX"
EXT_NAME = "DueWidget"
EXT_ID = "com.oliverullman.due.widget"

proj = Xcodeproj::Project.open("Overland.xcodeproj")
app = proj.targets.find { |t| t.name == "Due" } or abort "no Due target"
if proj.targets.any? { |t| t.name == EXT_NAME }
  puts "#{EXT_NAME} target already present"
  exit 0
end

ext = proj.new_target(:app_extension, EXT_NAME, :ios, "18.0")
group = proj.main_group.find_subpath(EXT_NAME, true)
group.set_source_tree("SOURCE_ROOT")
bundle = group.new_file("#{EXT_NAME}/DueWidgetBundle.swift")
intent = group.new_file("#{EXT_NAME}/DueComposeIntent.swift")
assets = group.new_file("#{EXT_NAME}/Assets.xcassets")
group.new_file("#{EXT_NAME}/Info.plist")
# The gem's default Foundation framework reference is pinned to one SDK version (see add_share_ext.rb).
ext.frameworks_build_phase.files.to_a.each(&:remove_from_project)
ext.add_file_references([bundle, intent])
ext.add_resources([assets])
app.add_file_references([intent])

ext.build_configurations.each do |c|
  c.build_settings.merge!(
    "PRODUCT_NAME" => "$(TARGET_NAME)",
    "PRODUCT_BUNDLE_IDENTIFIER" => EXT_ID,
    "INFOPLIST_FILE" => "#{EXT_NAME}/Info.plist",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "IPHONEOS_DEPLOYMENT_TARGET" => "18.0",
    "TARGETED_DEVICE_FAMILY" => "1",
    "SWIFT_VERSION" => "5.0",
    "SKIP_INSTALL" => "YES",
    "ENABLE_BITCODE" => "NO",
    "CODE_SIGN_STYLE" => "Manual",
    "DEVELOPMENT_TEAM" => TEAM,
    "PROVISIONING_PROFILE_SPECIFIER" => "Due Widget AdHoc",
    "CODE_SIGN_IDENTITY" => "Apple Distribution",
    "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
  )
end

app.add_dependency(ext)
embed = app.copy_files_build_phases.find { |p| p.symbol_dst_subfolder_spec == :plug_ins } or abort "no plug-ins embed phase"
embed.add_file_reference(ext.product_reference).settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }

proj.save
puts "Added #{EXT_NAME} (#{EXT_ID}) + embed in Due"
