#!/usr/bin/env ruby
# Adds the throwaway "DueSpike" SwiftUI app (com.oliverullman.duespike) plus its
# Notification Service Extension "DueSpikeNSE" (com.oliverullman.duespike.nse)
# to Overland.xcodeproj. Run via the gen-project workflow, commit the
# regenerated project.pbxproj. Idempotent.
require "xcodeproj"

TEAM = "J66WVM2DTX"
APP_ID = "com.oliverullman.duespike"
NSE_ID = "#{APP_ID}.nse"

proj = Xcodeproj::Project.open("Overland.xcodeproj")
if proj.targets.any? { |t| t.name == "DueSpike" }
  puts "DueSpike target already present"
  exit 0
end

def common(extra)
  {
    "PRODUCT_NAME" => "$(TARGET_NAME)",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "IPHONEOS_DEPLOYMENT_TARGET" => "16.0",
    "TARGETED_DEVICE_FAMILY" => "1",
    "SWIFT_VERSION" => "5.0",
    "ENABLE_BITCODE" => "NO",
    "CODE_SIGN_STYLE" => "Manual",
    "DEVELOPMENT_TEAM" => TEAM,
    "CODE_SIGN_IDENTITY" => "Apple Distribution",
  }.merge(extra)
end

# --- extension
nse = proj.new_target(:app_extension, "DueSpikeNSE", :ios, "16.0")
nse.frameworks_build_phase.files.to_a.each(&:remove_from_project)
ngroup = proj.main_group.find_subpath("DueSpikeNSE", true)
ngroup.set_source_tree("SOURCE_ROOT")
nse.add_file_references([ngroup.new_file("DueSpikeNSE/NotificationService.swift")])
ngroup.new_file("DueSpikeNSE/Info.plist")
nse.build_configurations.each do |c|
  c.build_settings.merge!(common(
    "PRODUCT_BUNDLE_IDENTIFIER" => NSE_ID,
    "INFOPLIST_FILE" => "DueSpikeNSE/Info.plist",
    "SKIP_INSTALL" => "YES",
    "PROVISIONING_PROFILE_SPECIFIER" => "DueSpike NSE AdHoc",
    "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
  ))
end

# --- app
app = proj.new_target(:application, "DueSpike", :ios, "16.0")
app.frameworks_build_phase.files.to_a.each(&:remove_from_project)
group = proj.main_group.find_subpath("DueSpikeApp", true)
group.set_source_tree("SOURCE_ROOT")
app.add_file_references([group.new_file("DueSpikeApp/DueSpikeApp.swift")])
group.new_file("DueSpikeApp/Info.plist")
group.new_file("DueSpikeApp/DueSpike.entitlements")
app.resources_build_phase.add_file_reference(group.new_file("DueSpikeApp/Assets.xcassets"), true)
app.build_configurations.each do |c|
  c.build_settings.merge!(common(
    "PRODUCT_BUNDLE_IDENTIFIER" => APP_ID,
    "INFOPLIST_FILE" => "DueSpikeApp/Info.plist",
    "CODE_SIGN_ENTITLEMENTS" => "DueSpikeApp/DueSpike.entitlements",
    "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
    "PROVISIONING_PROFILE_SPECIFIER" => "DueSpike AdHoc",
    "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/Frameworks"],
  ))
end

app.add_dependency(nse)
embed = app.new_copy_files_build_phase("Embed App Extensions")
embed.symbol_dst_subfolder_spec = :plug_ins
embed.dst_path = ""
embed.add_file_reference(nse.product_reference).settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }

proj.save
puts "Added DueSpike (#{APP_ID}) + DueSpikeNSE (#{NSE_ID})"
