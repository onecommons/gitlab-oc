# frozen_string_literal: true

require 'spec_helper'

# Unfurl writes machine-readable metadata into the job log and erases it with
# ESC[2K so a human tail does not see it. Both halves must reach the front end:
# the carriage return must not drop the line it wrote, and the erase must hide
# the segment rather than remove it.
RSpec.shared_examples 'keeps erased Unfurl metadata' do
  def convert_json(data)
    described_class.convert(StringIO.new(data)).lines
  end

  it 'keeps a line a carriage return would otherwise drop' do
    lines = convert_json("visible\rmetadata")

    expect(lines.first[:content].pluck(:text).join).to eq('visiblemetadata')
  end

  it 'hides an erased segment instead of dropping it' do
    lines = convert_json("metadata\e[2K\n")

    expect(lines.first[:content]).to include(hash_including(text: 'metadata', style: 'd-none'))
  end

  it 'leaves ordinary text and styling alone' do
    expect(convert_json('Hello')).to eq([{ offset: 0, content: [{ text: 'Hello' }] }])
  end

  it 'still reads a colour sequence' do
    lines = convert_json("\e[31mred")

    expect(lines.first[:content].first[:style]).to include('red')
  end
end

# The v2 converter sits behind ci_ansi2json_v2; patching only v1 would regress
# the day that flag flips.
RSpec.describe Gitlab::Ci::Ansi2json, feature_category: :continuous_integration do
  it_behaves_like 'keeps erased Unfurl metadata'
end

RSpec.describe Gitlab::Ci::Ansi2json::V2, feature_category: :continuous_integration do
  it_behaves_like 'keeps erased Unfurl metadata'
end
