#!/usr/bin/env ruby
# Adds "ShellTests": an XCTest bundle WITH a tiny host app ("ShellTestHost") for
# GLOfflineShell. Unlike the host-less SharedTests bundle, these tests drive a
# real WKWebView (JS evaluation, localStorage), which needs a host process with
# a UIApplication -- see SharedTests/GLWebKeyboardFocusTests.m. Run at CI time,
# never committed as a project diff. Idempotent.
require "xcodeproj"

TEAM = "J66WVM2DTX"
proj = Xcodeproj::Project.open("Overland.xcodeproj")
exit 0 if proj.targets.any? { |t| t.name == "ShellTests" }

host = proj.new_target(:application, "ShellTestHost", :ios, "15.0")
test = proj.new_target(:unit_test_bundle, "ShellTests", :ios, "15.0")

group = proj.main_group.find_subpath("ShellTests", true)
group.set_source_tree("SOURCE_ROOT")
host.add_file_references([group.new_reference("ShellTests/Host/main.m")])
info_ref = group.new_reference("ShellTests/Host/Info.plist")
test.add_file_references(Dir["ShellTests/*.m"].sort.map { |p| group.new_reference(p) })

shared_group = proj.main_group.find_subpath("Shared", false) or abort "no Shared group"
shell_ref = shared_group.files.find { |f| f.name == "GLOfflineShell.m" || f.path == "Shared/GLOfflineShell.m" } or abort "GLOfflineShell.m not in Shared group"
test.add_file_references([shell_ref])
test.add_dependency(host)

host.build_configurations.each do |c|
  s = c.build_settings
  s["PRODUCT_NAME"] = "ShellTestHost"
  s["PRODUCT_BUNDLE_IDENTIFIER"] = "com.oliverullman.assistantlocation.shelltesthost"
  s["INFOPLIST_FILE"] = "ShellTests/Host/Info.plist"
  s["GENERATE_INFOPLIST_FILE"] = "NO"
  s["CODE_SIGN_STYLE"] = "Automatic"
  s["DEVELOPMENT_TEAM"] = TEAM
  s["TARGETED_DEVICE_FAMILY"] = "1,2"
  s["IPHONEOS_DEPLOYMENT_TARGET"] = "15.0"
  s["CLANG_ENABLE_MODULES"] = "YES"
end

test.build_configurations.each do |c|
  s = c.build_settings
  s["PRODUCT_NAME"] = "ShellTests"
  s["PRODUCT_BUNDLE_IDENTIFIER"] = "com.oliverullman.assistantlocation.shelltests"
  s["GENERATE_INFOPLIST_FILE"] = "YES"
  s["CODE_SIGN_STYLE"] = "Automatic"
  s["DEVELOPMENT_TEAM"] = TEAM
  s["CLANG_ENABLE_MODULES"] = "YES"
  s["TARGETED_DEVICE_FAMILY"] = "1,2"
  s["IPHONEOS_DEPLOYMENT_TARGET"] = "15.0"
  s["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/ShellTestHost.app/ShellTestHost"
  s["BUNDLE_LOADER"] = "$(TEST_HOST)"
  s["LD_RUNPATH_SEARCH_PATHS"] = "$(inherited) @executable_path/Frameworks @loader_path/Frameworks"
  s["HEADER_SEARCH_PATHS"] = ["$(inherited)", "$(SRCROOT)/App", "$(SRCROOT)/Shared", "$(SRCROOT)/ShellTests"]
end

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(host)
scheme.add_build_target(test)
scheme.add_test_target(test)
scheme.save_as(proj.path, "ShellTests", true)
proj.save
puts "Added ShellTests target + ShellTests scheme"
