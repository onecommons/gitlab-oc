# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gitlab::JsonLogger do
  subject { described_class.new('/dev/null') }

  it_behaves_like 'a json logger', {}

  describe '#file_name' do
    let(:subclass) do
      Class.new(Gitlab::JsonLogger) do
        def self.file_name_noext
          'testlogger'
        end
      end
    end

    it 'raises error when file_name_noext not implemented' do
      expect { described_class.file_name }.to raise_error(
        'JsonLogger implementations must provide file_name_noext implementation'
      )
    end

    it 'returns log file name when file_name_noext is implemented' do
      expect(subclass.file_name).to eq('testlogger.log')
    end
  end

  # OC Change
  describe '.build' do
    let(:subclass) do
      Class.new(Gitlab::JsonLogger) do
        def self.file_name_noext
          'testlogger'
        end
      end
    end

    it 'reopens the log with the rotation Gitlab::Logger uses' do
      allow(Gitlab::Logger).to receive(:rotation).and_return([1, 100.megabytes])

      expect_next_instance_of(subclass) do |logger|
        expect(logger).to receive(:reopen).with(nil, 1, 100.megabytes)
      end

      subclass.build
    end

    it 'leaves the log alone without a rotation' do
      allow(Gitlab::Logger).to receive(:rotation).and_return([])

      expect_next_instance_of(subclass) do |logger|
        expect(logger).not_to receive(:reopen)
      end

      subclass.build
    end
  end
end
