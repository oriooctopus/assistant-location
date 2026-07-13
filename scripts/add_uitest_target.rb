#!/usr/bin/env ruby
# Adds a UI-test target ("UITests") to Overland.xcodeproj so we can build an
# XCUITest bundle for AWS Device Farm — done in code (via the xcodeproj gem)
# instead of Xcode's GUI. Idempotent: skips if the target already exists.
require "xcodeproj"

TEAM = "J66WVM2DTX"
proj = Xcodeproj::Project.open("Overland.xcodeproj")

if proj.targets.any? { |t| t.name == "UITests" }
  puts "UITests target already present"
  exit 0
end

app = proj.targets.find { |t| t.name == "Overland" } or abort "no Overland target"
test = proj.new_target(:ui_test_bundle, "UITests", :ios, "15.0")

group = proj.main_group.find_subpath("UITests", true)
group.set_source_tree("SOURCE_ROOT")
ref = group.new_file("UITests/LocationPermissionUITest.swift")
test.add_file_references([ref])
test.add_dependency(app)

test.build_configurations.each do |c|
  c.build_settings["TEST_TARGET_NAME"] = "Overland"
  c.build_settings["DEVELOPMENT_TEAM"] = TEAM
  c.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.oliverullman.assistantlocation.uitests"
  c.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  c.build_settings["SWIFT_VERSION"] = "5.0"
  c.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  c.build_settings["TARGETED_DEVICE_FAMILY"] = "1,2"
  c.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "15.0"
end

# A scheme that builds the app + is testable with the UITests target.
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(test)
scheme.set_launch_target(app)
scheme.save_as(proj.path, "OverlandUITests", true)

proj.save
puts "Added UITests target + OverlandUITests scheme"
