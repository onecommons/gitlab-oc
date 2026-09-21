#!/usr/bin/env ruby
# frozen_string_literal: true

# Prints the upstream specs covering files this fork edits in place, one per
# line, for `bundle exec rspec $(ruby oc/scripts/upstream_specs.rb)`.
#
#   ruby oc/scripts/upstream_specs.rb            # the spec_helper ones
#   ruby oc/scripts/upstream_specs.rb --fast     # the fast_spec_helper ones
#   ruby oc/scripts/upstream_specs.rb --heavy    # the four that dominate the clock
#   ruby oc/scripts/upstream_specs.rb --unmapped # edited files with no spec
#
# The two groups run separately: a fast_spec_helper spec boots no Rails and
# cannot share an invocation with one that does.
#
# Derived rather than listed, so it follows the `# OC Change` markers instead
# of drifting from them. It finds what a path implies and nothing else: a
# marked view or shared example whose consumers live elsewhere is reported by
# --unmapped, not guessed at.

require 'pathname'

# Specs the fork's edits reach but no path implies: a view whose subject is a
# mailer, a shared example whose consumers live elsewhere. Each says what it
# covers, so an entry that has outlived its edit is recognisable rather than
# cargo.
ALSO = {
  # app/views/layouts/notify.* -- the reply-by-email footer under every
  # notification, and the shared examples asserting it.
  'spec/mailers/notify_spec.rb' => 'layouts/notify.* footer',
  # app/views/notify/pages_domain_*.* and _removal_notification.html.haml
  'spec/mailers/emails/pages_domains_spec.rb' => 'notify/pages_domain_* copy',
  # app/views/notify/inactive_project_deletion_warning_email.*
  'spec/mailers/emails/projects_spec.rb' => 'notify/inactive_project_deletion_* copy'
}.freeze

# Four files are ~70% of the wall clock, because the fork edits big upstream
# classes and their specs are sized to match: the whole list is 8,000 examples
# and half an hour, without them it is a few minutes. They run on a schedule
# rather than on every push. notify_spec is deliberately not here -- it is
# large, but it covers the layout under every notification, which is where mail
# regressions actually turn up.
HEAVY = %w[
  spec/models/project_spec.rb
  spec/models/repository_spec.rb
  spec/policies/project_policy_spec.rb
  spec/requests/api/projects_spec.rb
].freeze

MARKED_DIRS = %w[app lib config db spec].freeze
EXTENSIONS = %w[rb haml erb yml].freeze
# Loaded by other specs rather than run, so rspec would find no examples.
NOT_RUNNABLE = %r{\Aspec/(support/|spec_helper\.rb\z)}
# Feature specs drive a real browser, which this job has no chromedriver for.
NEEDS_BROWSER = %r{\Aspec/features/}

def marked_files
  args = MARKED_DIRS + EXTENSIONS.map { |e| "--include=*.#{e}" }
  `grep -rl 'OC Change' #{args.join(' ')} 2>/dev/null`.split("\n")
end

def spec_for(file)
  return file if file.start_with?('spec/')

  base =
    if file.start_with?('app/')
      file.sub(%r{\Aapp/}, 'spec/')
    elsif file.start_with?('lib/')
      file.sub(%r{\Alib/}, 'spec/lib/')
    end

  return unless base

  # A view keeps its extensions: foo.html.haml -> foo.html.haml_spec.rb
  base.end_with?('.rb') ? "#{base.delete_suffix('.rb')}_spec.rb" : "#{base}_spec.rb"
end

specs = []
unmapped = []

marked_files.sort.each do |file|
  candidate = spec_for(file)

  if candidate.nil? || !File.exist?(candidate)
    unmapped << file
  elsif candidate.match?(NOT_RUNNABLE)
    unmapped << "#{file} (covered by #{candidate}, which other specs load)"
  elsif candidate.match?(NEEDS_BROWSER)
    unmapped << "#{file} (covered by #{candidate}, which needs a browser)"
  else
    specs << candidate
  end
end

missing_named = (ALSO.keys + HEAVY).reject { |path| File.exist?(path) }
unless missing_named.empty?
  warn "named specs that do not exist: #{missing_named.join(', ')}"
  exit 1
end

def fast?(spec)
  File.foreach(spec).any? { |line| line.include?('fast_spec_helper') }
end

if ARGV.include?('--unmapped')
  warn "#{unmapped.size} edited files have no spec this can find:"
  puts unmapped
else
  all = (specs + ALSO.keys).uniq.sort
  fast, slow = all.partition { |spec| fast?(spec) }
  heavy, light = slow.partition { |spec| HEAVY.include?(spec) }

  selected =
    if ARGV.include?('--fast')
      fast
    elsif ARGV.include?('--heavy')
      heavy
    else
      light
    end

  puts selected
end
