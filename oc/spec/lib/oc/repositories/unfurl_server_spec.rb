# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::Repositories::UnfurlServer, feature_category: :source_code_management do
  describe '.browser_url' do
    it 'prefers the environment, for an instance whose gitlab.yml it does not write' do
      stub_config(extra: { 'unfurl_server_url' => 'https://from-yaml' })
      stub_env('UNFURL_SERVER_URL', 'http://from-env')

      expect(described_class.browser_url).to eq('http://from-env')
    end

    it 'takes the config key when the environment is unset' do
      stub_config(extra: { 'unfurl_server_url' => 'https://from-yaml' })

      expect(described_class.browser_url).to eq('https://from-yaml')
    end

    # oc-pages reads a blank as "use the same-origin proxy path", so this has
    # to stay nil rather than become an empty string.
    it 'is blank when nothing names a server' do
      stub_config(extra: {})

      expect(described_class.browser_url).to be_blank
    end
  end

  describe '.internal_url' do
    it 'prefers the environment, which is the knob the chart leaves open' do
      stub_config(extra: { 'unfurl_server_internal_url' => 'http://from-yaml',
                           'unfurl_server_url' => 'https://browser' })
      stub_env('UNFURL_SERVER_INTERNAL_URL', 'http://from-env')

      expect(described_class.internal_url).to eq('http://from-env')
    end

    it 'takes the internal key when the environment is unset' do
      stub_config(extra: { 'unfurl_server_internal_url' => 'http://from-yaml',
                           'unfurl_server_url' => 'https://browser' })

      expect(described_class.internal_url).to eq('http://from-yaml')
    end

    # A GDK, or anything not behind a proxy, configures one URL and both
    # consumers use it. Nothing about this change should ask them for two.
    it "falls back to the browser's URL when only that is set" do
      stub_config(extra: { 'unfurl_server_url' => 'https://browser' })

      expect(described_class.internal_url).to eq('https://browser')
    end

    it 'is blank when nothing names a server, so callers stay switched off' do
      stub_config(extra: {})

      expect(described_class.internal_url).to be_blank
    end

    it 'ignores an empty setting rather than posting to the empty string' do
      stub_config(extra: { 'unfurl_server_internal_url' => '',
                           'unfurl_server_url' => 'https://browser' })

      expect(described_class.internal_url).to eq('https://browser')
    end
  end
end
