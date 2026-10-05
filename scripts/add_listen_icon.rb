#!/usr/bin/env ruby
# Adds ListenApp/Assets.xcassets (AppIcon) to the Listen target only and sets
# ASSETCATALOG_COMPILER_APPICON_NAME. Runs AFTER add_listen_app.rb (which
# creates the target); run via the gen-project workflow and commit the result.
# Idempotent.
require "xcodeproj"

proj = Xcodeproj::Project.open("Overland.xcodeproj")
target = proj.targets.find { |t| t.name == "Listen" } or abort "Listen target missing"

group = proj.main_group.find_subpath("ListenApp", false) or abort "ListenApp group missing"
ref = group.files.find { |f| f.path == "ListenApp/Assets.xcassets" } || group.new_file("ListenApp/Assets.xcassets")

phase = target.resources_build_phase
phase.add_file_reference(ref, true) unless phase.files_references.include?(ref)

target.build_configurations.each do |c|
  c.build_settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
end

proj.save
puts "Listen icon wired (#{phase.files.size} resources)"
