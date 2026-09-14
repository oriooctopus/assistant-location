#!/usr/bin/env ruby
# Wires the Quotes tab's pure-Foundation ObjC classes (QuotesModels,
# QuotesRuleEngine, QuotesStore) plus this widget's own two local ObjC
# files (JournalControl/QuotesWidgetLoader.h/.m) into the JournalControl
# extension target, and adds one small Swift shim
# (App/QuotesWidgetReload.swift) to the App target so QuotesStore.m's ObjC
# save call sites can trigger WidgetKit.WidgetCenter.reloadAllTimelines()
# (Swift-only API -- see that file's own header comment for why).
#
# JournalControl is a SHIPPED target -- its build product gets signed,
# embedded in the app, and OTA'd to a real phone -- unlike SharedTests,
# which is host-less, regenerated fresh on every unit-test.yml run, and
# never committed (see scripts/add_shared_tests_target.rb's own header).
# Precedent for a shipped target (every OTHER JournalControl file is an
# explicit PBXFileReference already sitting in a committed
# project.pbxproj, and none of ota.yml/build.yml/sim-test.yml invoke a
# project-mutation script the way unit-test.yml does for SharedTests) is to
# run this ONCE via gen-project.yml and commit the resulting
# project.pbxproj, not regenerate it at every build -- see
# .github/workflows/gen-project.yml's own header comment for that flow.
# Written idempotently regardless, in case it's ever re-run.
require "xcodeproj"

proj = Xcodeproj::Project.open("Overland.xcodeproj")

journal_control = proj.targets.find { |t| t.name == "JournalControl" } or abort "JournalControl target not found"
app_target = proj.targets.find { |t| t.name == "Overland" } or abort "Overland (app) target not found"

journal_control_group = proj.main_group.find_subpath("JournalControl", false) or abort "no JournalControl group found"
app_group = proj.main_group.find_subpath("App", false) or abort "no App group found"
# Modules/ itself is just confirmed to exist (sanity check that the
# synchronized-group assumption in the comments below still holds); the
# new_reference calls for Modules/Quotes/*.m go on journal_control_group
# instead -- PBXFileSystemSynchronizedRootGroup has no .new_reference (it
# isn't a plain PBXGroup), matching add_shared_tests_target.rb's identical
# pattern of creating fresh Modules/ references inside ITS OWN destination
# group (that script's `group` local, the SharedTests group) rather than
# inside the Modules group.
proj.main_group.find_subpath("Modules", false) or abort "no Modules group found (synchronized root group)"

already_wired = journal_control.source_build_phase.files.any? { |f| f.file_ref && f.file_ref.path.to_s.end_with?("QuotesStore.m") }
if already_wired
  puts "JournalControl already compiles QuotesStore.m -- skipping (idempotent)"
else
  # Modules/Quotes/*.m: Modules/ is a PBXFileSystemSynchronizedRootGroup
  # (see MODULES.md), so there is no existing PBXFileReference to reuse --
  # fresh references, exactly the same reasoning
  # scripts/add_shared_tests_target.rb uses for these same three files
  # (QuotesImportParser.m is deliberately NOT added here: the widget has no
  # import UI, so it would be dead weight in this target).
  quotes_models_ref = journal_control_group.new_reference("Modules/Quotes/QuotesModels.m")
  quotes_rule_engine_ref = journal_control_group.new_reference("Modules/Quotes/QuotesRuleEngine.m")
  quotes_store_ref = journal_control_group.new_reference("Modules/Quotes/QuotesStore.m")
  journal_control.add_file_references([quotes_models_ref, quotes_rule_engine_ref, quotes_store_ref])

  # stock-quotes.json: Resources, not Compile Sources -- QuotesStore's
  # designated initializer loads it eagerly (see QuotesStore.m), so this
  # process needs its own copy, exactly like SharedTests.xctest does (see
  # add_shared_tests_target.rb's identical addition, and the real bug it
  # fixed in CI runs 34865267084/34865623798 before that was added there).
  stock_quotes_ref = journal_control_group.new_reference("Modules/Quotes/stock-quotes.json")
  journal_control.resources_build_phase.add_file_reference(stock_quotes_ref)

  # This widget's own two local files -- JournalControl/ is an ordinary
  # explicit-reference group (unlike Modules/), so these get plain file
  # references straight into it, the same way every existing
  # JournalControl/*.swift file already does.
  loader_header_ref = journal_control_group.new_reference("JournalControl/QuotesWidgetLoader.h")
  loader_impl_ref = journal_control_group.new_reference("JournalControl/QuotesWidgetLoader.m")
  journal_control.add_file_references([loader_header_ref, loader_impl_ref])

  widget_ref = journal_control_group.new_reference("JournalControl/QuotesWidget.swift")
  journal_control.add_file_references([widget_ref])

  journal_control.add_system_framework("Security") # SecItem* in QuotesStore.m

  journal_control.build_configurations.each do |c|
    # QuotesWidget.swift (Swift) needs to see QuotesWidgetLoader.h (ObjC)
    # and the Quotes headers it re-exports -- a bridging header is a
    # PER-TARGET build setting, not shared across targets, so this is a
    # fresh header (JournalControl/JournalControl-Bridging-Header.h) even
    # though the App target already has its own
    # (App/Overland-Bridging-Header.h).
    c.build_settings["SWIFT_OBJC_BRIDGING_HEADER"] = "JournalControl/JournalControl-Bridging-Header.h"
    # QuotesStore.m/QuotesWidgetLoader.m #import "QuotesModels.h" etc. flat
    # -- same "Modules/Quotes" entry add_shared_tests_target.rb adds for
    # the identical reason, plus "Shared" for GLLog.h (QuotesStore.m
    # imports it; GLLog.h is header-only, Foundation-only, so it needs no
    # matching source-file addition, just to be findable by #import).
    c.build_settings["HEADER_SEARCH_PATHS"] = ["$(inherited)", "$(SRCROOT)/Shared", "$(SRCROOT)/Modules/Quotes"]
    c.build_settings["CLANG_ENABLE_MODULES"] = "YES"
  end

  puts "Wired QuotesModels.m/QuotesRuleEngine.m/QuotesStore.m + QuotesWidgetLoader + QuotesWidget.swift into JournalControl"
end

# App/QuotesWidgetReload.swift: the App target already has SWIFT_VERSION
# and SWIFT_OBJC_BRIDGING_HEADER set (project.pbxproj's App target build
# settings) despite having zero .swift files before this -- adding one here
# is enough for Xcode to auto-generate "Overland-Swift.h" for the ObjC
# Quotes*ViewController.m call sites to #import. App/ is also an ordinary
# explicit-reference group like JournalControl/, not synchronized.
app_already_wired = app_target.source_build_phase.files.any? { |f| f.file_ref && f.file_ref.path.to_s.end_with?("QuotesWidgetReload.swift") }
if app_already_wired
  puts "App target already compiles QuotesWidgetReload.swift -- skipping (idempotent)"
else
  # NOT "App/QuotesWidgetReload.swift" -- unlike journal_control_group
  # (sourceTree SOURCE_ROOT, no `path` of its own), app_group has `path =
  # App` set on itself already (sourceTree "<group>", resolved relative to
  # its parent), so a child path is relative to App/ already. Learned the
  # hard way: the first version of this script used the SOURCE_ROOT-style
  # "App/..." prefix here too and produced a literal "App/App/
  # QuotesWidgetReload.swift" file reference, which sim-test run
  # 34872740978's build failed on ("Build input file cannot be found").
  reload_ref = app_group.new_reference("QuotesWidgetReload.swift")
  app_target.add_file_references([reload_ref])
  puts "Added App/QuotesWidgetReload.swift to the Overland app target"
end

proj.save
puts "Saved project.pbxproj"
