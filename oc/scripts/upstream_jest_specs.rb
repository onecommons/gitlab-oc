#!/usr/bin/env ruby
# frozen_string_literal: true

# Prints the upstream Jest specs covering frontend files this fork edits in
# place, one per line, for `yarn jest $(ruby oc/scripts/upstream_jest_specs.rb)`.
# The Jest counterpart of upstream_specs.rb, derived from the `OC Change`
# markers the same way.
#
#   ruby oc/scripts/upstream_jest_specs.rb            # the runnable ones
#   ruby oc/scripts/upstream_jest_specs.rb --unmapped # edited files no spec here runs

MARKED_DIRS = %w[app/assets/javascripts ee/app/assets/javascripts spec/frontend ee/spec/frontend].freeze
EXTENSIONS = %w[js vue].freeze
# Fixtures come from `bin/rake frontend:fixtures`, which needs Rails and a
# database; the CI job that runs these has neither. Mock data files import
# them too, so the spec's own test imports are followed.
FIXTURE_IMPORT = %r{from 'test_fixtures/}
TEST_IMPORT = %r{from '(jest|ee_jest|helpers)/([^']+)'}
TEST_ROOTS = {
  'jest' => 'spec/frontend',
  'ee_jest' => 'ee/spec/frontend',
  'helpers' => 'spec/frontend/__helpers__'
}.freeze

def needs_fixtures?(path, seen = {})
  return false if seen[path]

  seen[path] = true
  source = File.read(path)
  return true if source.match?(FIXTURE_IMPORT)

  source.scan(TEST_IMPORT).any? do |root, rest|
    base = File.join(TEST_ROOTS.fetch(root), rest)
    imported = ["#{base}.js", File.join(base, 'index.js'), base].find { |p| File.file?(p) }
    imported && needs_fixtures?(imported, seen)
  end
end

def marked_files
  dirs = MARKED_DIRS.select { |dir| Dir.exist?(dir) }
  args = dirs + EXTENSIONS.map { |e| "--include=*.#{e}" }
  `grep -rl 'OC Change' #{args.join(' ')} 2>/dev/null`.split("\n")
end

def spec_for(file)
  return file if file.end_with?('_spec.js')
  return if file.include?('/spec/') || file.start_with?('spec/')

  file.sub(%r{\A(ee/)?app/assets/javascripts/}, '\1spec/frontend/').sub(/\.(js|vue)\z/, '_spec.js')
end

specs = []
unmapped = []

marked_files.sort.each do |file|
  candidate = spec_for(file)

  if candidate.nil?
    next
  elsif !File.exist?(candidate)
    unmapped << file
  elsif needs_fixtures?(candidate)
    unmapped << "#{file} (covered by #{candidate}, which needs generated fixtures)"
  else
    specs << candidate
  end
end

if ARGV.include?('--unmapped')
  warn "#{unmapped.size} edited files have no spec this can run:"
  puts unmapped
else
  puts specs.uniq.sort
end
