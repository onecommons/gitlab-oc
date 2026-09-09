# frozen_string_literal: true

require 'spec_helper'

# Guards the `# OC Change` on start_in's duration validator: a dashboard
# deployment sets the delay through the START_IN variable, so the value the
# job config carries is a variable reference rather than a duration.
RSpec.describe Gitlab::Ci::Config::Entry::Job, feature_category: :continuous_delivery do
  subject(:entry) { described_class.new(config, name: :deploy) }

  before do
    entry.compose!
  end

  context 'when start_in comes from a variable' do
    let(:config) { { script: 'echo', when: 'delayed', start_in: '$START_IN' } }

    it { is_expected.to be_valid }
  end

  context 'when start_in is a literal beyond the limit' do
    let(:config) { { script: 'echo', when: 'delayed', start_in: '2 weeks' } }

    it 'still refuses it, because only a variable skips the check' do
      expect(entry).not_to be_valid
      expect(entry.errors).to include(/should not exceed the limit/)
    end
  end
end
