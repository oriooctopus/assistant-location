#!/usr/bin/env ruby
# Adds the "JournalControl" widget-extension target (a lock-screen Control) to
# Overland.xcodeproj using the xcodeproj gem. See scripts/add_share_ext.rb,
# which this closely mirrors.
#
# The RESULT is committed — this script is not run during a normal build. Run
# it via the gen-project workflow (macOS runner has the gem) when the target's
# structure needs to change, then commit the regenerated project.pbxproj.
# Idempotent: exits early when the target is already there.
require "xcodeproj"

TEAM = "J66WVM2DTX"
EXT_NAME = "JournalControl"
APP_ID = "com.oliverullman.assistantlocation"
EXT_ID = "#{APP_ID}.journalcontrol"
APP_PROFILE = "AssistantLocation AppStore"
EXT_PROFILE = "AssistantLocation JournalControl AppStore"

proj = Xcodeproj::Project.open("Overland.xcodeproj")
app = proj.targets.find { |t| t.name == "Overland" } or abort "no Overland target"

if proj.targets.any? { |t| t.name == EXT_NAME }
  puts "#{EXT_NAME} target already present"
  exit 0
end

ext = proj.new_target(:app_extension, EXT_NAME, :ios, "18.0")

group = proj.main_group.find_subpath(EXT_NAME, true)
group.set_source_tree("SOURCE_ROOT")
ext.add_file_references([group.new_file("#{EXT_NAME}/JournalControlBundle.swift")])
%w[Info.plist JournalControl.entitlements].each do |f|
  group.new_file("#{EXT_NAME}/#{f}")
end
# See the note in add_share_ext.rb: the gem's default Foundation framework
# reference is pinned to one SDK version and breaks the simulator build.
ext.frameworks_build_phase.files.to_a.each(&:remove_from_project)

ext.build_configurations.each do |c|
  c.build_settings.merge!(
    "PRODUCT_NAME" => "$(TARGET_NAME)",
    "PRODUCT_BUNDLE_IDENTIFIER" => EXT_ID,
    "INFOPLIST_FILE" => "#{EXT_NAME}/Info.plist",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "CODE_SIGN_ENTITLEMENTS" => "#{EXT_NAME}/#{EXT_NAME}.entitlements",
    "IPHONEOS_DEPLOYMENT_TARGET" => "18.0",
    "TARGETED_DEVICE_FAMILY" => "1,2",
    "SWIFT_VERSION" => "5.0",
    "SKIP_INSTALL" => "YES",
    "ENABLE_BITCODE" => "NO",
    "CODE_SIGN_STYLE" => "Manual",
    "DEVELOPMENT_TEAM" => TEAM,
    # Per-target so the app and the extension can each get their own profile;
    # a global xcargs override would force one profile onto both and fail.
    "PROVISIONING_PROFILE_SPECIFIER" => EXT_PROFILE,
    "CODE_SIGN_IDENTITY" => "Apple Distribution",
    "LD_RUNPATH_SEARCH_PATHS" => [
      "$(inherited)",
      "@executable_path/Frameworks",
      "@executable_path/../../Frameworks",
    ],
  )
end

app.build_configurations.each do |c|
  c.build_settings["PROVISIONING_PROFILE_SPECIFIER"] = APP_PROFILE
  # CODE_SIGN_ENTITLEMENTS is already committed on the app target (it needs
  # Overland.entitlements for Siri + wifi-info already); only set it if a
  # future project regeneration ever lost it.
  c.build_settings["CODE_SIGN_ENTITLEMENTS"] ||= "Overland.entitlements"
end

app.add_dependency(ext)

embed = app.copy_files_build_phases.find { |p| p.symbol_dst_subfolder_spec == :plug_ins }
embed ||= app.new_copy_files_build_phase("Embed App Extensions")
embed.symbol_dst_subfolder_spec = :plug_ins
embed.dst_path = ""
embed.add_file_reference(ext.product_reference).settings = {
  "ATTRIBUTES" => ["RemoveHeadersOnCopy"],
}

proj.save
puts "Added #{EXT_NAME} target (#{EXT_ID}) + embed phase"
