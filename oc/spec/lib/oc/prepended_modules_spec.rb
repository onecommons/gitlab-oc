# frozen_string_literal: true

require 'spec_helper'

# A module that is never prepended fails silently: the fork's method is simply
# not called, and nothing says so. Two things cause it, and both survive a
# rebase unannounced -- upstream drops the `prepend_mod` call the module hangs
# off, or the file lands one directory shy of its `oc/` segment and defines the
# upstream constant instead of the `OC::` one, where CE's copy wins and this
# one is never loaded.
RSpec.describe 'OC module prepends', feature_category: :rails_platform do
  # Module#name through an unbound method: a few upstream modules define their
  # own `name`, and calling theirs raises here.
  def module_name(mod)
    Module.instance_method(:name).bind_call(mod)
  rescue StandardError
    nil
  end

  def oc_modules
    ObjectSpace.each_object(Module).select { |mod| module_name(mod)&.start_with?('OC::') }
  end

  # A module reaches its target as an instance prepend or, where upstream keeps
  # the method in `class << self`, as a singleton one.
  def prepended?(mod, upstream)
    upstream.ancestors.include?(mod) || upstream.singleton_class.ancestors.include?(mod)
  end

  it 'prepends every override onto the constant it shadows' do
    Rails.application.eager_load!

    checked = 0
    missing = oc_modules.filter_map do |mod|
      name = module_name(mod)
      upstream_name = name.delete_prefix('OC::')

      upstream = begin
        Object.const_get(upstream_name, false)
      rescue NameError
        next # fork-only, so there is nothing to shadow
      end

      next unless upstream.is_a?(Module)
      next if upstream.equal?(mod)
      # A namespace defines nothing and prepends nowhere.
      next if mod.instance_methods(false).empty? && mod.private_instance_methods(false).empty?

      checked += 1
      "#{name} is not prepended to #{upstream_name}" unless prepended?(mod, upstream)
    end

    expect(missing).to be_empty, -> { missing.sort.join("\n") }
    # Guards the guard: a resolution change that found nothing would otherwise
    # pass silently, which is the failure this spec exists to catch.
    expect(checked).to be > 40
  end
end
