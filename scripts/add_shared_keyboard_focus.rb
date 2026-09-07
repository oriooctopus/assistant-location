#!/usr/bin/env ruby
# Adds Shared/GLWebKeyboardFocus.{h,m} to Overland.xcodeproj: a
# PBXFileReference for each (in the existing Shared/ group, which is a plain
# group, NOT a PBXFileSystemSynchronizedRootGroup -- unlike Modules/, files
# under Shared/ are invisible to the build until something puts a reference
# here) plus a Sources-build-phase entry for the .m on the Overland (app)
# target only. Modelled on refactor_foundation.rb's step 3
# (find_or_add_shared_file) and add_shared_tests_target.rb's reuse-by-name
# pattern -- see MODULES.md for the synchronized-vs-plain-group distinction.
#
# The RESULT (project.pbxproj) is committed -- this script is not run during
# a normal build. Run it via the gen-project workflow (macOS runner has the
# `xcodeproj` gem; this Linux dev box does not) and commit the regenerated
# project.pbxproj. Idempotent: safe to re-run, skips whatever already exists.
require "xcodeproj"

proj = Xcodeproj::Project.open("Overland.xcodeproj")
app = proj.targets.find { |t| t.name == "Overland" } or abort "no Overland target"

main_group = proj.main_group
shared_group = main_group.children.find { |g| g.respond_to?(:name) && g.name == "Shared" }
abort "cannot find the existing Shared group" unless shared_group

SHARED_SOURCES = %w[GLWebKeyboardFocus.m].freeze
SHARED_HEADERS = %w[GLWebKeyboardFocus.h].freeze

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

proj.save
puts "== Saved Overland.xcodeproj/project.pbxproj =="
