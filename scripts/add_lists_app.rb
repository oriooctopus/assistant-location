#!/usr/bin/env ruby
# Adds the standalone "Lists" application target (com.oliverullman.lists) AND its embedded
# "ListsWidget" extension target (com.oliverullman.lists.widget) to Overland.xcodeproj.
# Modeled on add_gripes_app.rb (web-hosting app, bundled page) plus add_quotes_app.rb /
# add_quotes_widget_ext.rb (Swift shim, entitlements, embedded WidgetKit extension), in ONE script
# so a single gen-project dispatch produces the whole pbxproj change.
#
# Run via the gen-project workflow (input script=add_lists_app.rb), commit the regenerated
# project.pbxproj. Idempotent: each target is skipped when already present.
require "xcodeproj"

TEAM = "J66WVM2DTX"
NAME = "Lists"
APP_ID = "com.oliverullman.lists"
PROFILE = "Lists AdHoc"
EXT_NAME = "ListsWidget"
EXT_ID = "com.oliverullman.lists.widget"
EXT_PROFILE = "Lists Widget AdHoc"

# Bundle resources are flattened into the app root, so the names must be unique. page.css is NOT
# bundled: gl-bridge.js does not reference it (only Gripes' own html does), so Lists has no use for it.
WEB_FILES = %w[lists.html lists.css lists-core.js lists-ui.js lists-dict.js].map { |f| "ListsApp/web/#{f}" } +
            %w[Modules/WebPages/gl-bridge.js]

# Fail BEFORE touching the project: a missing page file would otherwise surface much later as a
# runtime assert in ListsViewController (lists.html missing from the bundle) or a white screen.
missing = WEB_FILES.reject { |f| File.exist?(f) }
abort "missing bundle resources (page not written yet?): #{missing.join(', ')}" unless missing.empty?

proj = Xcodeproj::Project.open("Overland.xcodeproj")

if proj.targets.any? { |t| t.name == NAME }
  puts "#{NAME} target already present"
  target = proj.targets.find { |t| t.name == NAME }
else
  target = proj.new_target(:application, NAME, :ios, "15.0")

  group = proj.main_group.find_subpath("ListsApp", true)
  group.set_source_tree("SOURCE_ROOT")

  # ListsWidgetReload.swift is the one Swift file (the WidgetCenter shim), compiled with the .m files.
  sources = Dir["ListsApp/*.m"].sort + Dir["ListsApp/*.swift"].sort
  abort "no sources in ListsApp/" if sources.empty?
  target.add_file_references(sources.map { |f| group.new_file(f) })
  (Dir["ListsApp/*.h"].sort + ["ListsApp/Info.plist", "ListsApp/Lists.entitlements"]).each { |f| group.new_file(f) }

  target.resources_build_phase.add_file_reference(group.new_file("ListsApp/Assets.xcassets"), true)
  WEB_FILES.each { |f| target.resources_build_phase.add_file_reference(group.new_file(f), true) }

  # Same reasoning as add_quotes_app.rb: drop the SDK-versioned framework path the gem adds;
  # clang module auto-linking links UIKit/WebKit/WidgetKit from the #imports.
  target.frameworks_build_phase.files.to_a.each(&:remove_from_project)

  target.build_configurations.each do |c|
    c.build_settings.merge!(
      "PRODUCT_NAME" => "$(TARGET_NAME)",
      "PRODUCT_BUNDLE_IDENTIFIER" => APP_ID,
      "INFOPLIST_FILE" => "ListsApp/Info.plist",
      "GENERATE_INFOPLIST_FILE" => "NO",
      "IPHONEOS_DEPLOYMENT_TARGET" => "15.0",
      "TARGETED_DEVICE_FAMILY" => "1",
      "CLANG_ENABLE_MODULES" => "YES",
      "ENABLE_BITCODE" => "NO",
      "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
      # ListsStateStore.m imports "Lists-Swift.h" (GLListsWidgetReload). The header name is pinned so
      # it does not depend on the module name derivation; this target is the only Swift user of it.
      "SWIFT_VERSION" => "5.0",
      "SWIFT_OBJC_INTERFACE_HEADER_NAME" => "Lists-Swift.h",
      # BakedConfig.h lives in App/ (CI overwrites it with the real host/token).
      "HEADER_SEARCH_PATHS" => ["$(inherited)", "$(SRCROOT)/App", "$(SRCROOT)/ListsApp"],
      "CODE_SIGN_ENTITLEMENTS" => "ListsApp/Lists.entitlements",
      "CODE_SIGN_STYLE" => "Manual",
      "DEVELOPMENT_TEAM" => TEAM,
      "PROVISIONING_PROFILE_SPECIFIER" => PROFILE,
      "CODE_SIGN_IDENTITY" => "Apple Distribution",
      "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/Frameworks"],
    )
  end
  puts "Added #{NAME} target (#{APP_ID}); blueprint id #{target.uuid}"
end

if proj.targets.any? { |t| t.name == EXT_NAME }
  puts "#{EXT_NAME} target already present"
else
  ext = proj.new_target(:app_extension, EXT_NAME, :ios, "17.0")
  ext.frameworks_build_phase.files.to_a.each(&:remove_from_project)

  group = proj.main_group.find_subpath(EXT_NAME, true)
  group.set_source_tree("SOURCE_ROOT")
  sources = Dir["ListsWidget/*.swift"].sort
  abort "no sources in ListsWidget/" if sources.empty?
  ext.add_file_references(sources.map { |f| group.new_file(f) })
  %w[ListsWidget/Info.plist ListsWidget/ListsWidget.entitlements].each { |f| group.new_file(f) }

  ext.build_configurations.each do |c|
    c.build_settings.merge!(
      "PRODUCT_NAME" => "$(TARGET_NAME)",
      "PRODUCT_BUNDLE_IDENTIFIER" => EXT_ID,
      "INFOPLIST_FILE" => "ListsWidget/Info.plist",
      "GENERATE_INFOPLIST_FILE" => "NO",
      "CODE_SIGN_ENTITLEMENTS" => "ListsWidget/ListsWidget.entitlements",
      # ListsWidget.swift uses .containerBackground (iOS 17).
      "IPHONEOS_DEPLOYMENT_TARGET" => "17.0",
      "TARGETED_DEVICE_FAMILY" => "1",
      "SWIFT_VERSION" => "5.0",
      "CLANG_ENABLE_MODULES" => "YES",
      "SKIP_INSTALL" => "YES",
      "ENABLE_BITCODE" => "NO",
      "CODE_SIGN_STYLE" => "Manual",
      "DEVELOPMENT_TEAM" => TEAM,
      "PROVISIONING_PROFILE_SPECIFIER" => EXT_PROFILE,
      "CODE_SIGN_IDENTITY" => "Apple Distribution",
      "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
    )
  end

  target.add_dependency(ext)
  embed = target.new_copy_files_build_phase("Embed App Extensions")
  embed.symbol_dst_subfolder_spec = :plug_ins
  embed.dst_path = ""
  embed.add_file_reference(ext.product_reference).settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }
  puts "Added #{EXT_NAME} target (#{EXT_ID}) and embedded it in #{NAME}"
end

proj.save
