#!/usr/bin/env ruby
# Regenerates Overland.xcodeproj/project.pbxproj for the foundation refactor:
# deletes the tip-jar/trip/endpoint fork features, moves GLManager + friends
# into a new Location/ library group, adds the new Shared/ platform-layer
# files to the Overland target only, registers Location.storyboard, renames
# the GPSLogger/ group to App/, and rewrites the GPSLogger-prefixed build
# settings. See the plan doc for the full rationale.
#
# The RESULT is committed — this script is not run during a normal build. Run
# it via the gen-project workflow (macOS runner has the gem) when the
# project's structure needs to change, then commit the regenerated
# project.pbxproj.
#
# Idempotent-and-updating, modelled on add_journal_control_ext.rb (the only
# other script in this repo with that property): every step first checks
# whether it already happened and either updates in place or skips, so
# re-running this after a partial or full previous run is always safe.
require "xcodeproj"

proj = Xcodeproj::Project.open("Overland.xcodeproj")
app = proj.targets.find { |t| t.name == "Overland" } or abort "no Overland target"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Every PBXBuildFile anywhere in the project (any target, any build phase)
# whose file_ref is `ref`. Used instead of trusting PBXFileReference#remove_
# from_project to cascade into build-phase membership on its own: removing a
# file reference only clears back-references TO the ref itself (e.g. a
# group's children array) — a PBXBuildFile that points AT the ref would be
# left with a nil file_ref, silently dangling in its build phase, which is a
# broken project. Removing the PBXBuildFile explicitly first sidesteps that
# because PBXBuildPhase#files IS a direct back-reference to the PBXBuildFile
# object, so PBXBuildFile#remove_from_project correctly detaches it from
# whichever phase holds it.
def build_files_for(proj, ref)
  files = []
  proj.targets.each do |t|
    t.build_phases.each do |phase|
      next unless phase.respond_to?(:files)
      phase.files.each { |bf| files << bf if bf.respond_to?(:file_ref) && bf.file_ref == ref }
    end
  end
  files
end

# Finds a PBXFileReference by exact `path` (or, for frameworks, `name`) and
# removes it plus every PBXBuildFile referencing it. No-ops (idempotent) if
# the reference is already gone.
def purge(proj, label, &finder)
  ref = finder.call
  unless ref
    puts "  [skip] #{label}: already removed"
    return
  end
  bfs = build_files_for(proj, ref)
  bfs.each(&:remove_from_project)
  ref.remove_from_project
  puts "  [removed] #{label} (+ #{bfs.size} build file entr#{bfs.size == 1 ? 'y' : 'ies'})"
end

# Moves an existing PBXFileReference from `source_group` into `location_group`,
# rewriting its `path` and preserving its UUID (so the existing PBXBuildFile /
# Sources-phase entry for it stays valid). No-ops if `source_group` is nil (a
# group already fully drained by a previous run) or the ref isn't found under
# it (already moved).
def reparent_into_location(source_group, location_group, old_path, new_path)
  unless source_group
    puts "  [skip] #{old_path}: source group already gone (already moved)"
    return
  end
  ref = source_group.children.find { |c| c.respond_to?(:path) && c.path == old_path }
  unless ref
    puts "  [skip] #{new_path}: already moved"
    return
  end
  source_group.children.delete(ref)
  ref.path = new_path
  location_group.children << ref unless location_group.children.include?(ref)
  puts "  [moved] #{old_path} -> #{new_path} (uuid #{ref.uuid} preserved)"
end

# ---------------------------------------------------------------------------
# 1. Remove deleted files (file refs + their PBXBuildFiles, wherever used)
# ---------------------------------------------------------------------------
puts "== Removing deleted-feature files =="

DELETED_BY_PATH = %w[
  TipJarViewController.h
  TipJarViewController.m
  TripModeViewController.h
  TripModeViewController.m
  TripSettingsViewController.h
  TripSettingsViewController.m
  EndpointViewController.h
  EndpointViewController.m
  Tips.storekit
  Fonts/OpenSansCondensed-Light.ttf
].freeze

DELETED_BY_PATH.each do |path|
  purge(proj, path) { proj.files.find { |f| f.path == path } }
end

# The tip jar was the only StoreKit consumer; nothing else references the
# framework once it's gone.
purge(proj, "StoreKit.framework") { proj.files.find { |f| f.name == "StoreKit.framework" } }

# ---------------------------------------------------------------------------
# 2. Location/ group: reparent GLManager, LOLDatabase, NSArray+map,
#    WifiZoneViewController into it, preserving their PBXFileReference UUIDs.
# ---------------------------------------------------------------------------
puts "== Building Location/ group =="

main_group = proj.main_group

location_group = main_group.children.find { |g| g.respond_to?(:name) && g.name == "Location" }
if location_group
  puts "  [skip] Location group already present"
else
  location_group = main_group.find_subpath("Location", true)
  location_group.set_source_tree("SOURCE_ROOT")
  puts "  [created] Location group (sourceTree = SOURCE_ROOT)"
end

# The App/GPSLogger shell group — found by either name, so this step is safe
# to run before or after the rename in step 5.
app_group = main_group.children.find { |g| g.respond_to?(:path) && %w[GPSLogger App].include?(g.path) }
abort "cannot find the GPSLogger/App shell group" unless app_group

loldb_group = app_group.children.find { |g| g.respond_to?(:name) && g.name == "LOLDB" }

MOVED_FROM_APP_GROUP = {
  "GLManager.h" => "Location/GLManager.h",
  "GLManager.m" => "Location/GLManager.m",
  "NSArray+map.h" => "Location/NSArray+map.h",
  "NSArray+map.m" => "Location/NSArray+map.m",
  "WifiZoneViewController.h" => "Location/WifiZoneViewController.h",
  "WifiZoneViewController.m" => "Location/WifiZoneViewController.m",
}.freeze

MOVED_FROM_APP_GROUP.each do |old_path, new_path|
  reparent_into_location(app_group, location_group, old_path, new_path)
end

MOVED_FROM_LOLDB_GROUP = {
  "LOLDatabase.h" => "Location/LOLDatabase.h",
  "LOLDatabase.m" => "Location/LOLDatabase.m",
}.freeze

MOVED_FROM_LOLDB_GROUP.each do |old_path, new_path|
  reparent_into_location(loldb_group, location_group, old_path, new_path)
end

if loldb_group && loldb_group.children.empty?
  loldb_group.remove_from_project
  puts "  [removed] now-empty LOLDB group"
end

# ---------------------------------------------------------------------------
# 3. Shared/ new files: file refs for all, Sources-phase entries for the four
#    .m files on the Overland (app) target ONLY — never ShareToDesktop or
#    JournalControl.
# ---------------------------------------------------------------------------
puts "== Adding Shared/ platform-layer files =="

shared_group = main_group.children.find { |g| g.respond_to?(:name) && g.name == "Shared" }
abort "cannot find the existing Shared group" unless shared_group

SHARED_SOURCES = %w[GLTheme.m GLWebModuleViewController.m GLComponents.m GLFormat.m].freeze
SHARED_HEADERS = %w[
  GLTheme.h GLWebModuleViewController.h GLComponents.h GLFormat.h
  GLHaptics.h GLLog.h GLDefaultsKeys.h
].freeze

def find_or_add_shared_file(proj, shared_group, filename)
  path = "Shared/#{filename}"
  existing = proj.files.find { |f| f.path == path }
  return existing if existing
  ref = shared_group.new_file(path)
  ref.name = filename
  ref
end

(SHARED_SOURCES + SHARED_HEADERS).each do |filename|
  ref = find_or_add_shared_file(proj, shared_group, filename)
  if SHARED_SOURCES.include?(filename)
    already = app.source_build_phase.files_references.include?(ref)
    app.add_file_references([ref]) unless already
    puts "  [#{already ? 'skip' : 'added'}] Shared/#{filename}: file ref + Overland Sources entry"
  else
    puts "  [ok] Shared/#{filename}: file ref (header, no build-phase entry)"
  end
end

# ---------------------------------------------------------------------------
# 4. Location/Base.lproj/Location.storyboard: register as a PBXVariantGroup
#    in the app target's Resources phase, mirroring Main.storyboard exactly.
# ---------------------------------------------------------------------------
puts "== Registering Location.storyboard =="

existing_variant = location_group.children.find { |c| c.respond_to?(:name) && c.name == "Location.storyboard" }
if existing_variant
  puts "  [skip] Location.storyboard variant group already present"
else
  base_ref = proj.new(Xcodeproj::Project::Object::PBXFileReference)
  base_ref.last_known_file_type = "file.storyboard"
  base_ref.name = "Base"
  base_ref.path = "Location/Base.lproj/Location.storyboard"
  base_ref.source_tree = "<group>"

  variant = proj.new(Xcodeproj::Project::Object::PBXVariantGroup)
  variant.name = "Location.storyboard"
  variant.source_tree = "<group>"
  variant.children << base_ref

  location_group.children << variant

  build_file = proj.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.file_ref = variant
  app.resources_build_phase.files << build_file

  puts "  [added] Location.storyboard variant group + Overland Resources entry"
end

# ---------------------------------------------------------------------------
# 5. Rename the shell group: GPSLogger -> App. ONE edit — children store
#    paths relative to this group and must not be touched, or they resolve to
#    App/App/... and the build fails.
# ---------------------------------------------------------------------------
puts "== Renaming GPSLogger group to App =="

if app_group.path == "App"
  puts "  [skip] shell group already named App"
else
  app_group.path = "App"
  puts "  [renamed] shell group path GPSLogger -> App (#{app_group.children.size} children left untouched)"
end

# ---------------------------------------------------------------------------
# 6. Build settings: INFOPLIST_FILE, SWIFT_OBJC_BRIDGING_HEADER and
#    HEADER_SEARCH_PATHS on both Debug and Release of the Overland target.
# ---------------------------------------------------------------------------
puts "== Rewriting Overland build settings =="

app.build_configurations.each do |c|
  bs = c.build_settings

  if bs["INFOPLIST_FILE"] == "GPSLogger/Info.plist"
    bs["INFOPLIST_FILE"] = "App/Info.plist"
  end

  if bs["SWIFT_OBJC_BRIDGING_HEADER"] == "GPSLogger/Overland-Bridging-Header.h"
    bs["SWIFT_OBJC_BRIDGING_HEADER"] = "App/Overland-Bridging-Header.h"
  end

  hsp = bs["HEADER_SEARCH_PATHS"]
  if hsp.is_a?(Array)
    hsp.map! { |p| p == "$(SRCROOT)/GPSLogger" ? "$(SRCROOT)/App" : p }
    hsp << "$(SRCROOT)/Location" unless hsp.include?("$(SRCROOT)/Location")
  end

  puts "  [#{c.name}] INFOPLIST_FILE=#{bs['INFOPLIST_FILE']}"
  puts "  [#{c.name}] SWIFT_OBJC_BRIDGING_HEADER=#{bs['SWIFT_OBJC_BRIDGING_HEADER']}"
  puts "  [#{c.name}] HEADER_SEARCH_PATHS=#{hsp.inspect}"
end

proj.save
puts "== Saved Overland.xcodeproj/project.pbxproj =="
