#!/usr/bin/env ruby
# Adds a standalone (host-less) unit-test bundle target ("SharedTests") to
# Overland.xcodeproj so Shared/ classes with no UIKit/app dependency (right
# now: GLTodoOutbox) can be exercised with plain XCTest, no Overland.app
# launch required. Mirrors scripts/add_uitest_target.rb's approach exactly
# (done in code via the xcodeproj gem, run at CI time, never committed as a
# generated project diff) but for a logic-test bundle instead of a UI-test
# bundle, so it deliberately skips that script's TEST_TARGET_NAME/
# add_dependency wiring -- a host-less bundle has no host target to depend
# on or launch. Idempotent: skips if the target already exists.
require "xcodeproj"

TEAM = "J66WVM2DTX"
proj = Xcodeproj::Project.open("Overland.xcodeproj")

if proj.targets.any? { |t| t.name == "SharedTests" }
  puts "SharedTests target already present"
  exit 0
end

test = proj.new_target(:unit_test_bundle, "SharedTests", :ios, "15.0")

group = proj.main_group.find_subpath("SharedTests", true)
group.set_source_tree("SOURCE_ROOT")
test_refs = Dir["SharedTests/*.m"].sort.map { |path| group.new_file(path) }
test.add_file_references(test_refs)

# GLTodoOutbox.m already has a PBXFileReference in the Shared group (it's
# compiled into the real Overland app target too -- see project.pbxproj).
# Reusing that SAME reference here means this test bundle compiles the
# actual production file, not a second copy of it. Matched on `name`, not
# `path` -- the Shared group itself carries no `path` (it's a virtual
# grouping folder), so each file's own `path` is project-relative
# ("Shared/GLTodoOutbox.m"), not bare -- `name` is the one attribute set to
# the plain filename.
shared_group = proj.main_group.find_subpath("Shared", false) or abort "no Shared group found"
outbox_ref = shared_group.files.find { |f| f.name == "GLTodoOutbox.m" || f.path == "Shared/GLTodoOutbox.m" } or abort "GLTodoOutbox.m file reference not found in Shared group -- was it added to the project?"
test.add_file_references([outbox_ref])

# GLTabBarButtonLocator.m lives in Modules/Todos/, a
# PBXFileSystemSynchronizedRootGroup (see project.pbxproj's "Begin
# PBXFileSystemSynchronizedRootGroup section") -- unlike Shared/, that kind
# of group has NO PBXFileReference for any of its files (the synced-group
# mechanism resolves them at build time instead), so there is nothing to
# reuse here the way outbox_ref is reused above. A fresh file reference,
# added straight into the SharedTests group, is the only way to compile this
# production file into the test bundle too.
locator_ref = group.new_reference("Modules/Todos/GLTabBarButtonLocator.m")
test.add_file_references([locator_ref])

# GLWebKeyboardFocus.m lives in Shared/, so its PBXFileReference is reused the
# same way GLTodoOutbox.m's is above rather than created fresh. It is compiled
# in so GLWebKeyboardFocusTests can install the real swizzles and assert
# against a real WKWebView -- the accessory-bar suppression is only meaningful
# as "does an actual WKContentView return nil", which needs the production
# file, not a reimplementation of it.
focus_ref = shared_group.files.find { |f| f.name == "GLWebKeyboardFocus.m" || f.path == "Shared/GLWebKeyboardFocus.m" } or abort "GLWebKeyboardFocus.m file reference not found in Shared group -- run scripts/add_shared_keyboard_focus.rb first"
test.add_file_references([focus_ref])

test.build_configurations.each do |c|
  c.build_settings["PRODUCT_NAME"] = "SharedTests"
  c.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.oliverullman.assistantlocation.sharedtests"
  c.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  c.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  c.build_settings["DEVELOPMENT_TEAM"] = TEAM
  c.build_settings["SWIFT_VERSION"] = "5.0"
  # GLWebKeyboardFocusTests #imports <WebKit/WebKit.h>; module autolinking
  # is what pulls WebKit.framework in without an explicit link phase entry.
  # Set explicitly rather than relying on the template default, since this
  # target is generated from scratch by this script on every CI run.
  c.build_settings["CLANG_ENABLE_MODULES"] = "YES"
  c.build_settings["ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES"] = "NO"
  c.build_settings["TARGETED_DEVICE_FAMILY"] = "1,2"
  c.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "15.0"
  c.build_settings["LD_RUNPATH_SEARCH_PATHS"] = "$(inherited) @executable_path/Frameworks @loader_path/Frameworks"
  # Same "App" + "Shared" entries as the Overland target's own
  # HEADER_SEARCH_PATHS -- GLTodoOutbox.m #imports "BakedConfig.h" (App/)
  # and "GLLog.h" (Shared/) with flat, no-path #imports, same as every
  # other Shared/*.m file, so this target needs the identical search paths
  # to resolve them. "Modules/Todos" is added for the same reason:
  # GLTabBarButtonLocatorTests.m #imports "GLTabBarButtonLocator.h" flat,
  # and that header lives in Modules/Todos/, not one of the two paths above.
  c.build_settings["HEADER_SEARCH_PATHS"] = ["$(inherited)", "$(SRCROOT)/App", "$(SRCROOT)/Shared", "$(SRCROOT)/Modules/Todos"]
  # Deliberately no TEST_HOST / BUNDLE_LOADER: a standalone "logic test"
  # bundle needs no host app to launch, and no dependency edge onto
  # Overland -- which matters because a dependency edge would make the
  # Overland target's own archive/beta/adhoc builds try to build (and
  # code-sign) this bundle too, and it has no matching provisioning profile.
end

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(test)
scheme.add_test_target(test)
scheme.save_as(proj.path, "SharedTests", true)

proj.save
puts "Added SharedTests target + SharedTests scheme"
