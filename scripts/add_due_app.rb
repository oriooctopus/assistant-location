#!/usr/bin/env ruby
# Adds the "Due" app (com.oliverullman.due, display name "Due Clone") plus its Notification Service Extension "DueNSE"
# (com.oliverullman.due.nse) to Overland.xcodeproj, and writes the shared Due scheme. Run via the gen-project workflow,
# commit the regenerated project.pbxproj and Due.xcscheme. Idempotent.
require "xcodeproj"

TEAM = "J66WVM2DTX"
APP_ID = "com.oliverullman.due"
NSE_ID = "#{APP_ID}.nse"

proj = Xcodeproj::Project.open("Overland.xcodeproj")
if proj.targets.any? { |t| t.name == "Due" }
  puts "Due target already present"
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
nse = proj.new_target(:app_extension, "DueNSE", :ios, "16.0")
nse.frameworks_build_phase.files.to_a.each(&:remove_from_project)
ngroup = proj.main_group.find_subpath("DueNSE", true)
ngroup.set_source_tree("SOURCE_ROOT")
nse.add_file_references([ngroup.new_file("DueNSE/NotificationService.swift")])
ngroup.new_file("DueNSE/Info.plist")
nse.build_configurations.each do |c|
  c.build_settings.merge!(common(
    "PRODUCT_BUNDLE_IDENTIFIER" => NSE_ID,
    "INFOPLIST_FILE" => "DueNSE/Info.plist",
    "SKIP_INSTALL" => "YES",
    "PROVISIONING_PROFILE_SPECIFIER" => "Due NSE AdHoc",
    "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
  ))
end

# --- app
app = proj.new_target(:application, "Due", :ios, "16.0")
app.frameworks_build_phase.files.to_a.each(&:remove_from_project)
group = proj.main_group.find_subpath("DueApp", true)
group.set_source_tree("SOURCE_ROOT")
sources = %w[AppDelegate WebViewController Web Storage Notifications BakedConfig].map { |n| group.new_file("DueApp/#{n}.swift") }
app.add_file_references(sources)
group.new_file("DueApp/Info.plist")
group.new_file("DueApp/DueApp.entitlements")
app.resources_build_phase.add_file_reference(group.new_file("DueApp/Assets.xcassets"), true)
# Web/ is a blue folder reference: copied into the bundle as-is, served at due-app://app/
web = group.new_file("DueApp/Web")
web.last_known_file_type = "folder"
app.resources_build_phase.add_file_reference(web, true)
app.build_configurations.each do |c|
  c.build_settings.merge!(common(
    "PRODUCT_BUNDLE_IDENTIFIER" => APP_ID,
    "INFOPLIST_FILE" => "DueApp/Info.plist",
    "CODE_SIGN_ENTITLEMENTS" => "DueApp/DueApp.entitlements",
    "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
    "PROVISIONING_PROFILE_SPECIFIER" => "Due AdHoc",
    "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/Frameworks"],
  ))
end

app.add_dependency(nse)
embed = app.new_copy_files_build_phase("Embed App Extensions")
embed.symbol_dst_subfolder_spec = :plug_ins
embed.dst_path = ""
embed.add_file_reference(nse.product_reference).settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }

proj.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.save_as("Overland.xcodeproj", "Due", true)
puts "Added Due (#{APP_ID}) + DueNSE (#{NSE_ID}) + shared scheme Due"
