#!/usr/bin/env ruby
# Adds "DueTests": a host-less XCTest bundle for the pure prune rules in DueApp/Sweep.swift (which also pulls in Keychain.swift
# and BakedConfig.swift, since Sweep references them). Run at CI time by unit-test.yml, never committed as a project diff
# (the dev box has no ruby). Idempotent. Mirrors add_shared_tests_target.rb.
require "xcodeproj"

TEAM = "J66WVM2DTX"
proj = Xcodeproj::Project.open("Overland.xcodeproj")
exit 0 if proj.targets.any? { |t| t.name == "DueTests" }

test = proj.new_target(:unit_test_bundle, "DueTests", :ios, "16.0")
group = proj.main_group.find_subpath("DueTests", true)
group.set_source_tree("SOURCE_ROOT")
# Full project-relative paths, as add_shell_tests_target.rb does: this group has a SOURCE_ROOT source tree and no path of its own.
refs = Dir["DueTests/*.swift"].sort.map { |p| group.new_reference(p) }
# The app's own files, reusing the project's existing references so the bundle compiles the production code, not a copy.
due = %w[Sweep Keychain BakedConfig].map do |n|
  proj.files.find { |f| f.real_path.to_s.end_with?("/DueApp/#{n}.swift") } or abort "DueApp/#{n}.swift has no file reference in the project"
end
test.add_file_references(refs + due)

test.build_configurations.each do |c|
  s = c.build_settings
  s["PRODUCT_NAME"] = "DueTests"
  s["PRODUCT_BUNDLE_IDENTIFIER"] = "com.oliverullman.due.tests"
  s["GENERATE_INFOPLIST_FILE"] = "YES"
  s["CODE_SIGN_STYLE"] = "Automatic"
  s["DEVELOPMENT_TEAM"] = TEAM
  s["SWIFT_VERSION"] = "5.0"
  s["TARGETED_DEVICE_FAMILY"] = "1"
  s["IPHONEOS_DEPLOYMENT_TARGET"] = "16.0"
  s["LD_RUNPATH_SEARCH_PATHS"] = "$(inherited) @executable_path/Frameworks @loader_path/Frameworks"
end

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(test)
scheme.add_test_target(test)
scheme.save_as(proj.path, "DueTests", true)
proj.save
puts "Added DueTests target + DueTests scheme"
