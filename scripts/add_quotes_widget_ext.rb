#!/usr/bin/env ruby
# Moves the Quotes home-screen widget out of Overland's JournalControl extension
# and into its own "QuotesWidget" extension target (com.oliverullman.quotes.widget)
# embedded in the standalone Quotes app. Run via the gen-project workflow and
# commit the regenerated project.pbxproj, like add_quotes_app.rb.
#
# Idempotent: every step checks current state first.
#  1. JournalControl: drop every Quotes source/resource/header, the Security
#     framework, the bridging header and the Modules/Quotes header search path.
#  2. Overland: drop App/QuotesWidgetReload.swift (only the Quotes app needs it).
#  3. Create the QuotesWidget extension and embed it in Quotes.app.
require "xcodeproj"

TEAM = "J66WVM2DTX"
EXT_NAME = "QuotesWidget"
EXT_ID = "com.oliverullman.quotes.widget"
EXT_PROFILE = "Quotes Widget AdHoc"

proj = Xcodeproj::Project.open("Overland.xcodeproj")
jc = proj.targets.find { |t| t.name == "JournalControl" } or abort "no JournalControl target"
overland = proj.targets.find { |t| t.name == "Overland" } or abort "no Overland target"
quotes = proj.targets.find { |t| t.name == "Quotes" } or abort "no Quotes target"

# 1. JournalControl cleanup
quotesy = ->(ref) { ref && ref.path.to_s =~ /Quotes|stock-quotes/ }
[jc.source_build_phase, jc.resources_build_phase, jc.headers_build_phases.first].compact.each do |phase|
  phase.files.to_a.select { |bf| quotesy.call(bf.file_ref) }.each(&:remove_from_project)
end
jc.frameworks_build_phase.files.to_a.each(&:remove_from_project) # only Security was ever added
jc.build_configurations.each do |c|
  c.build_settings.delete("SWIFT_OBJC_BRIDGING_HEADER")
  c.build_settings.delete("HEADER_SEARCH_PATHS")
  c.build_settings.delete("CLANG_ENABLE_MODULES")
end
jc_group = proj.main_group.find_subpath("JournalControl", false) or abort "no JournalControl group"
jc_group.recursive_children.select { |o| o.isa == "PBXFileReference" && quotesy.call(o) }.each(&:remove_from_project)

# 2. Overland no longer compiles App/QuotesWidgetReload.swift. Two file refs
# exist: the App-group one (Overland only) and the one under QuotesApp (Quotes).
overland.source_build_phase.files.to_a.select { |bf| bf.file_ref && bf.file_ref.path.to_s.end_with?("QuotesWidgetReload.swift") }.each do |bf|
  ref = bf.file_ref
  bf.remove_from_project
  ref.remove_from_project if ref.referrers.none? { |r| r.isa == "PBXBuildFile" }
end

# 3. The new extension
if proj.targets.any? { |t| t.name == EXT_NAME }
  puts "#{EXT_NAME} target already present"
else
  ext = proj.new_target(:app_extension, EXT_NAME, :ios, "17.0")
  ext.frameworks_build_phase.files.to_a.each(&:remove_from_project)

  group = proj.main_group.find_subpath(EXT_NAME, true)
  group.set_source_tree("SOURCE_ROOT")
  sources = %w[QuotesWidget/QuotesWidget.swift QuotesWidget/QuotesWidgetBundle.swift QuotesWidget/QuotesWidgetLoader.m
               QuotesApp/Sources/QuotesModels.m QuotesApp/Sources/QuotesRuleEngine.m QuotesApp/Sources/QuotesStore.m]
  ext.add_file_references(sources.map { |f| group.new_file(f) })
  %w[QuotesWidget/QuotesWidgetLoader.h QuotesWidget/QuotesWidget-Bridging-Header.h
     QuotesWidget/Info.plist QuotesWidget/QuotesWidget.entitlements].each { |f| group.new_file(f) }
  # QuotesStore's initializer loads stock-quotes.json eagerly.
  ext.resources_build_phase.add_file_reference(group.new_file("QuotesApp/Sources/stock-quotes.json"), true)

  ext.build_configurations.each do |c|
    c.build_settings.merge!(
      "PRODUCT_NAME" => "$(TARGET_NAME)",
      "PRODUCT_BUNDLE_IDENTIFIER" => EXT_ID,
      "INFOPLIST_FILE" => "QuotesWidget/Info.plist",
      "GENERATE_INFOPLIST_FILE" => "NO",
      "CODE_SIGN_ENTITLEMENTS" => "QuotesWidget/QuotesWidget.entitlements",
      # QuotesWidget.swift uses .containerBackground (iOS 17).
      "IPHONEOS_DEPLOYMENT_TARGET" => "17.0",
      "TARGETED_DEVICE_FAMILY" => "1",
      "SWIFT_VERSION" => "5.0",
      "SWIFT_OBJC_BRIDGING_HEADER" => "QuotesWidget/QuotesWidget-Bridging-Header.h",
      "CLANG_ENABLE_MODULES" => "YES",
      "HEADER_SEARCH_PATHS" => ["$(inherited)", "$(SRCROOT)/Shared", "$(SRCROOT)/QuotesApp/Sources"],
      "SKIP_INSTALL" => "YES",
      "ENABLE_BITCODE" => "NO",
      "CODE_SIGN_STYLE" => "Manual",
      "DEVELOPMENT_TEAM" => TEAM,
      "PROVISIONING_PROFILE_SPECIFIER" => EXT_PROFILE,
      "CODE_SIGN_IDENTITY" => "Apple Distribution",
      "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
    )
  end

  quotes.add_dependency(ext)
  embed = quotes.new_copy_files_build_phase("Embed App Extensions")
  embed.symbol_dst_subfolder_spec = :plug_ins
  embed.dst_path = ""
  embed.add_file_reference(ext.product_reference).settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }
  puts "Added #{EXT_NAME} target (#{EXT_ID}) and embedded it in Quotes"
end

proj.save
