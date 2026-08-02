#!/usr/bin/env ruby
# Adds a "Generate build stamp" Run Script phase to the Overland target.
#
# The phase writes BuildStamp.generated.h into DERIVED_FILE_DIR on EVERY build
# (alwaysOutOfDate), so the on-screen stamp reflects when the binary was
# actually compiled. It replaced reading CFBundleVersion, which is a literal in
# Info.plist and only ever rewritten by fastlane — so every simulator build
# reported the value committed with the original fork.
#
# ENABLE_USER_SCRIPT_SANDBOXING is YES project-wide, so the generated header
# must be a declared output for the script to be allowed to write it.
#
# Run on a macOS runner via the gen-project workflow; the dev box is Linux and
# has no ruby/xcodeproj. Idempotent.

require 'xcodeproj'

PHASE_NAME = 'Generate build stamp'.freeze
HEADER = 'BuildStamp.generated.h'.freeze

project_path = File.expand_path('../Overland.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'Overland' }
abort 'no Overland target in the project' if target.nil?

# Drop any previous copy so re-runs don't stack duplicates.
target.build_phases
      .select { |p| p.respond_to?(:name) && p.name == PHASE_NAME }
      .each { |p| target.build_phases.delete(p) }

phase = project.new(Xcodeproj::Project::Object::PBXShellScriptBuildPhase)
phase.name = PHASE_NAME
phase.shell_path = '/bin/sh'
phase.output_paths = ["$(DERIVED_FILE_DIR)/#{HEADER}"]
phase.always_out_of_date = '1'
phase.shell_script = <<~SH
  set -e
  mkdir -p "$DERIVED_FILE_DIR"
  printf '#define GL_BUILD_STAMP @"%s"\\n' "$(date -u '+%Y-%m-%d %H:%M')" \\
    > "$DERIVED_FILE_DIR/#{HEADER}"
  cat "$DERIVED_FILE_DIR/#{HEADER}"
SH

target.build_phases << phase
target.build_phases.move(phase, 0) # must precede Compile Sources

# The generated header lives in the build dir, not the source tree.
# DERIVED_FILE_DIR is arch-scoped while compiling but not while the script
# runs, so both spellings of that directory go on the search path.
target.build_configurations.each do |config|
  existing = config.build_settings['HEADER_SEARCH_PATHS']
  paths = case existing
          when nil then ['$(inherited)']
          when String then [existing]
          else existing.dup
          end
  paths << '$(inherited)' unless paths.include?('$(inherited)')
  ['$(DERIVED_FILE_DIR)', '$(DERIVED_SOURCES_DIR)'].each do |p|
    paths << p unless paths.include?(p)
  end
  config.build_settings['HEADER_SEARCH_PATHS'] = paths
end

project.save
puts "added '#{PHASE_NAME}' to #{target.name} (phase index 0)"
