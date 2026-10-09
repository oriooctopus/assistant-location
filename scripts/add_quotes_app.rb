#!/usr/bin/env ruby
# Adds the standalone "Quotes" application target (com.oliverullman.quotes) to
# Overland.xcodeproj, modeled on add_listen_app.rb + add_listen_icon.rb +
# add_build_stamp_phase.rb. App-only sources live in QuotesApp/; the Quotes UI
# and store live in QuotesApp/Sources/ (the QuotesWidget extension, see
# add_quotes_widget_ext.rb, and SharedTests reference them by path) and are
# referenced explicitly here, as are the Shared/ theme files and the Swift
# WidgetKit shim.
#
# Run via the gen-project workflow, commit the regenerated project.pbxproj.
# Idempotent: exits early when the target is already there.
require "xcodeproj"

TEAM = "J66WVM2DTX"
NAME = "Quotes"
APP_ID = "com.oliverullman.quotes"
PROFILE = "Quotes AdHoc"
STAMP_PHASE = "Generate build stamp"
STAMP_HEADER = "BuildStamp.generated.h"

proj = Xcodeproj::Project.open("Overland.xcodeproj")
if proj.targets.any? { |t| t.name == NAME }
  puts "#{NAME} target already present"
  exit 0
end

target = proj.new_target(:application, NAME, :ios, "15.0")

group = proj.main_group.find_subpath("QuotesApp", true)
group.set_source_tree("SOURCE_ROOT")

quotes_sources = Dir["QuotesApp/Sources/*.m"].sort
sources = Dir["QuotesApp/*.m"].sort + quotes_sources +
          %w[Shared/GLTheme.m Shared/GLComponents.m Shared/GLAppStateReporter.m App/QuotesWidgetReload.swift]
abort "no sources in QuotesApp/" if Dir["QuotesApp/*.m"].empty?
target.add_file_references(sources.map { |f| group.new_file(f) })

# Headers and plist only for the Xcode navigator.
(Dir["QuotesApp/*.h"].sort + ["QuotesApp/Info.plist", "QuotesApp/Quotes.entitlements"]).each { |f| group.new_file(f) }

target.resources_build_phase.add_file_reference(group.new_file("QuotesApp/Sources/stock-quotes.json"), true)
target.resources_build_phase.add_file_reference(group.new_file("QuotesApp/Assets.xcassets"), true)

# Same reasoning as add_share_ext.rb: drop the SDK-versioned framework path the
# gem adds; clang module auto-linking links UIKit/Security/UserNotifications/
# WidgetKit from the #imports.
target.frameworks_build_phase.files.to_a.each(&:remove_from_project)

target.build_configurations.each do |c|
  c.build_settings.merge!(
    "PRODUCT_NAME" => "$(TARGET_NAME)",
    "PRODUCT_BUNDLE_IDENTIFIER" => APP_ID,
    "INFOPLIST_FILE" => "QuotesApp/Info.plist",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "IPHONEOS_DEPLOYMENT_TARGET" => "15.0",
    "TARGETED_DEVICE_FAMILY" => "1",
    "CLANG_ENABLE_MODULES" => "YES",
    "ENABLE_BITCODE" => "NO",
    "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
    # The one .swift file (WidgetKit shim) generates this header; the module
    # is named Quotes, but QuotesApp/Sources sources import "Overland-Swift.h".
    "SWIFT_VERSION" => "5.0",
    "SWIFT_OBJC_INTERFACE_HEADER_NAME" => "Overland-Swift.h",
    # BakedConfig.h (App/) for QuotesAIFilterClient; DERIVED_FILE_DIR for the
    # generated build stamp (both spellings, see add_build_stamp_phase.rb).
    "HEADER_SEARCH_PATHS" => ["$(inherited)", "$(SRCROOT)/App", "$(SRCROOT)/Shared", "$(SRCROOT)/QuotesApp/Sources",
                              "$(SRCROOT)/QuotesApp", "$(DERIVED_FILE_DIR)", "$(DERIVED_SOURCES_DIR)"],
    "CODE_SIGN_ENTITLEMENTS" => "QuotesApp/Quotes.entitlements",
    "CODE_SIGN_STYLE" => "Manual",
    "DEVELOPMENT_TEAM" => TEAM,
    "PROVISIONING_PROFILE_SPECIFIER" => PROFILE,
    "CODE_SIGN_IDENTITY" => "Apple Distribution",
    "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/Frameworks"],
  )
end

# Build stamp: GLAppStateReporter.m imports BuildStamp.generated.h.
phase = proj.new(Xcodeproj::Project::Object::PBXShellScriptBuildPhase)
phase.name = STAMP_PHASE
phase.shell_path = "/bin/sh"
phase.output_paths = ["$(DERIVED_FILE_DIR)/#{STAMP_HEADER}"]
phase.always_out_of_date = "1"
phase.shell_script = <<~SH
  set -e
  mkdir -p "$DERIVED_FILE_DIR"
  printf '#define GL_BUILD_STAMP @"%s"\\n' "$(date -u '+%Y-%m-%d %H:%M')" \\
    > "$DERIVED_FILE_DIR/#{STAMP_HEADER}"
  cat "$DERIVED_FILE_DIR/#{STAMP_HEADER}"
SH
target.build_phases << phase
target.build_phases.move(phase, 0) # must precede Compile Sources

proj.save
puts "Added #{NAME} target (#{APP_ID}); blueprint id #{target.uuid}"
