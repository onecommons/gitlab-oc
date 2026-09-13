# frozen_string_literal: true

RSpec.shared_examples 'CI variable' do
  it { is_expected.to include_module(Ci::HasVariable) }

  describe "variable type" do
    it 'defines variable types' do
      # OC Change -- unencrypted_var; see Ci::HasVariable#should_encrypt?
      expect(described_class.variable_types).to eq({ "env_var" => 1, "file" => 2, "unencrypted_var" => 3 })
    end

    it "defaults variable type to env_var" do
      expect(subject.variable_type).to eq("env_var")
    end

    it "supports variable type file" do
      variable = described_class.new(variable_type: :file)
      expect(variable).to be_file
    end
  end

  it 'strips whitespaces when assigning key' do
    subject.key = " SECRET "
    expect(subject.key).to eq("SECRET")
  end

  it 'can convert to hash variable' do
    expect(subject.to_hash_variable.keys).to include(:key, :value, :public, :file)
  end
end
