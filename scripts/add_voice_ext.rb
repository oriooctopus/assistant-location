#!/usr/bin/env ruby
# Adds the "VoiceToDesktop" Action extension ("Voice chat" in the share sheet's
# action list) to Overland.xcodeproj. It compiles ShareToDesktop's
# ShareViewController.m with GL_VOICE_ACTION=1, which skips the /drop upload and
# the buttons and goes straight to the voice session. An Action extension (not a
# second share extension) because iOS draws every share extension in the app
# row with the containing app's icon and name, so two would look identical.
#
# Same workflow as add_share_ext.rb: run via gen-project, commit the result.
# Idempotent: exits early when the target is already there.
require "xcodeproj"

TEAM = "J66WVM2DTX"
EXT_NAME = "VoiceToDesktop"
SHARE_NAME = "ShareToDesktop"
APP_ID = "com.oliverullman.assistantlocation"
EXT_ID = "#{APP_ID}.voice"
EXT_PROFILE = "AssistantLocation Voice AppStore"

proj = Xcodeproj::Project.open("Overland.xcodeproj")
app = proj.targets.find { |t| t.name == "Overland" } or abort "no Overland target"
share = proj.targets.find { |t| t.name == SHARE_NAME } or abort "no #{SHARE_NAME} target"

if proj.targets.any? { |t| t.name == EXT_NAME }
  puts "#{EXT_NAME} target already present"
  exit 0
end

ext = proj.new_target(:app_extension, EXT_NAME, :ios, "15.0")

group = proj.main_group.find_subpath(EXT_NAME, true)
group.set_source_tree("SOURCE_ROOT")
%w[Info.plist VoiceToDesktop.entitlements].each do |f|
  group.new_file("#{EXT_NAME}/#{f}")
end
assets = group.new_file("#{EXT_NAME}/Assets.xcassets")
ext.add_resources([assets])

# Reuse the share extension's existing source file references (no duplicate
# files, no second copy to keep in step): the view controller and the two
# Shared/ classes it calls.
%w[ShareToDesktop/ShareViewController.m Shared/GLDropUploader.m Shared/GLDropBackground.m].each do |path|
  ref = proj.files.find { |f| f.path == path } or abort "no file reference for #{path}"
  ext.add_file_references([ref])
end
# See add_share_ext.rb: drop the SDK-version-pinned Foundation reference.
ext.frameworks_build_phase.files.to_a.each(&:remove_from_project)

ext.build_configurations.each do |c|
  c.build_settings.merge!(
    "PRODUCT_NAME" => "$(TARGET_NAME)",
    "PRODUCT_BUNDLE_IDENTIFIER" => EXT_ID,
    "INFOPLIST_FILE" => "#{EXT_NAME}/Info.plist",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "CODE_SIGN_ENTITLEMENTS" => "#{EXT_NAME}/#{EXT_NAME}.entitlements",
    "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
    "GCC_PREPROCESSOR_DEFINITIONS" => ["$(inherited)", "GL_VOICE_ACTION=1"],
    "IPHONEOS_DEPLOYMENT_TARGET" => "15.0",
    "TARGETED_DEVICE_FAMILY" => "1,2",
    "SKIP_INSTALL" => "YES",
    "CLANG_ENABLE_MODULES" => "YES",
    "ENABLE_BITCODE" => "NO",
    "CODE_SIGN_STYLE" => "Manual",
    "DEVELOPMENT_TEAM" => TEAM,
    "PROVISIONING_PROFILE_SPECIFIER" => EXT_PROFILE,
    "CODE_SIGN_IDENTITY" => "Apple Distribution",
    "LD_RUNPATH_SEARCH_PATHS" => [
      "$(inherited)",
      "@executable_path/Frameworks",
      "@executable_path/../../Frameworks",
    ],
  )
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
