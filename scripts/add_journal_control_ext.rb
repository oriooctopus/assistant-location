#!/usr/bin/env ruby
# Adds the "JournalControl" widget-extension target (a lock-screen Control) to
# Overland.xcodeproj using the xcodeproj gem. See scripts/add_share_ext.rb,
# which this closely mirrors.
#
# The RESULT is committed — this script is not run during a normal build. Run
# it via the gen-project workflow (macOS runner has the gem) when the target's
# structure needs to change, then commit the regenerated project.pbxproj.
#
# Idempotent-and-updating: the target itself is created only once, but build
# settings and source-file membership (including JournalIntent.swift, shared
# between the extension and the app target — see JournalControl/JournalIntent.swift
# for why) are always re-applied so re-running after the target already
# exists still picks up changes.
require "xcodeproj"

TEAM = "J66WVM2DTX"
EXT_NAME = "JournalControl"
APP_ID = "com.oliverullman.assistantlocation"
EXT_ID = "#{APP_ID}.journalcontrol"
APP_PROFILE = "AssistantLocation AppStore"
EXT_PROFILE = "AssistantLocation JournalControl AppStore"

proj = Xcodeproj::Project.open("Overland.xcodeproj")
app = proj.targets.find { |t| t.name == "Overland" } or abort "no Overland target"

ext = proj.targets.find { |t| t.name == EXT_NAME }

if ext
  puts "#{EXT_NAME} target already present; re-applying settings"
else
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
end

# Finds an existing PBXFileReference for `path` anywhere in the project, or
# creates one under `group`. Prevents duplicate file references when this
# script runs again after the target already exists.
def find_or_add_file_ref(proj, group, path)
  proj.files.find { |f| f.path == path } || group.new_file(path)
end

journal_intent_path = "#{EXT_NAME}/JournalIntent.swift"
ext_group = proj.main_group.find_subpath(EXT_NAME, true)
journal_intent_ref = find_or_add_file_ref(proj, ext_group, journal_intent_path)

# Ensure JournalIntent.swift is a source of both the extension and the app
# target, without adding it twice to either target's build phase.
[ext, app].each do |target|
  already_present = target.source_build_phase.files_references.include?(journal_intent_ref)
  target.add_file_references([journal_intent_ref]) unless already_present
end

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
  # JournalIntent.swift is now compiled into the app target too (mixed
  # ObjC/Swift target), so the app target needs a Swift version set.
  c.build_settings["SWIFT_VERSION"] = "5.0"
end

app.add_dependency(ext) unless app.dependencies.any? { |d| d.target == ext }

embed = app.copy_files_build_phases.find { |p| p.symbol_dst_subfolder_spec == :plug_ins }
embed ||= app.new_copy_files_build_phase("Embed App Extensions")
embed.symbol_dst_subfolder_spec = :plug_ins
embed.dst_path = ""
unless embed.files_references.include?(ext.product_reference)
  embed.add_file_reference(ext.product_reference).settings = {
    "ATTRIBUTES" => ["RemoveHeadersOnCopy"],
  }
end

proj.save
puts "Added/updated #{EXT_NAME} target (#{EXT_ID}) + embed phase"
