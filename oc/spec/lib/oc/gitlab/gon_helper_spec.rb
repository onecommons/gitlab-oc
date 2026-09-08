# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gitlab::GonHelper, feature_category: :source_code_management do
  let(:helper) do
    Class.new do
      include Gitlab::GonHelper
    end.new
  end

  describe '#add_gon_variables' do
    let(:gon) { double('gon').as_null_object } # rubocop:disable RSpec/VerifiedDoubles -- gon builds its setters with method_missing

    before do
      allow(helper).to receive_messages(current_user: nil, gon: gon)
    end

    it 'sets unfurl_server_url from extra.unfurl_server_url' do
      stub_config(extra: { unfurl_server_url: 'https://unfurl.example.com' })

      expect(gon).to receive(:unfurl_server_url=).with('https://unfurl.example.com')

      helper.add_gon_variables
    end

    it 'leaves unfurl_server_url unset when the setting is absent' do
      stub_config(extra: {})

      expect(gon).not_to receive(:unfurl_server_url=)

      helper.add_gon_variables
    end
  end
end
