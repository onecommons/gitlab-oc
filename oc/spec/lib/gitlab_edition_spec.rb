# frozen_string_literal: true

require 'fast_spec_helper'

RSpec.describe GitlabEdition, feature_category: :rails_platform do
  def remove_instance_variable(ivar)
    described_class.remove_instance_variable(ivar) if described_class.instance_variable_defined?(ivar)
  end

  before do
    stub_env('FOSS_ONLY', nil)
    stub_env('EE_ONLY', nil)
    stub_env('GITLAB_ONLY', nil)

    %i[@is_ee @is_jh @is_oc].each { |ivar| remove_instance_variable(ivar) }
  end

  after do
    %i[@is_ee @is_jh @is_oc].each { |ivar| remove_instance_variable(ivar) }
  end

  describe '.oc?' do
    it 'is true when oc/ exists' do
      expect(described_class.oc?).to be(true)
    end

    it 'is false when GITLAB_ONLY is set' do
      stub_env('GITLAB_ONLY', '1')

      expect(described_class.oc?).to be(false)
    end
  end

  describe '.ee?' do
    it 'is false in the oc edition even when ee/ is present' do
      expect(described_class.ee?).to be(false)
    end
  end

  describe '.jh?' do
    it 'is false in the oc edition' do
      expect(described_class.jh?).to be(false)
    end
  end

  describe '.extensions' do
    it 'is only oc' do
      expect(described_class.extensions).to eq(%w[oc])
    end
  end

  describe '.extension_path_prefixes' do
    it 'globs CE and oc' do
      expect(described_class.extension_path_prefixes).to eq('{,oc/}')
    end
  end
end
