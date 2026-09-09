# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gitlab::ContentSecurityPolicy::ConfigLoader, feature_category: :system_access do
  it 'allows framing the crossorigin relay, and nothing else beside it' do
    frame_src = described_class.default_directives['frame_src']

    expect(frame_src).to include('http://localhost/-/oc/assets/crossorigin-xhr.html')
    expect(frame_src).not_to include('http://localhost/-/oc/assets/arbitrary.html')
  end
end
