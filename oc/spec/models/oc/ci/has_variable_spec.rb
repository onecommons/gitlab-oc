# frozen_string_literal: true

require 'spec_helper'

# oc-pages sends every deployment variable as `unencrypted_var`, and the deploy
# endpoint passes the client's type straight through, so without this type a
# deployment raises ArgumentError before a pipeline is created. Storing them in
# the clear is what lets a blueprint's deployments be found by value.
RSpec.describe Ci::HasVariable, feature_category: :continuous_integration do
  let_it_be(:pipeline) { create(:ci_pipeline) }

  let(:url) { 'https://unfurl.cloud/onecommons/blueprints/minecraft.git' }

  # Assignment order is load-bearing: attr_encrypted encrypts in `value=`, so
  # should_encrypt? sees whatever variable_type holds at that moment. These
  # build explicitly rather than through the factory, which assigns in its own
  # order -- and quietly encrypts as a result.
  def build_variable(type, type_first: true)
    variable = Ci::PipelineVariable.new(pipeline: pipeline, project_id: pipeline.project_id,
      key: 'BLUEPRINT_PROJECT_URL')

    if type_first
      variable.variable_type = type
      variable.value = url
    else
      variable.value = url
      variable.variable_type = type
    end

    variable.tap(&:save!)
  end

  def stored_value(variable)
    Ci::PipelineVariable.where(id: variable.id).pick(:encrypted_value)
  end

  it 'accepts the fork variable type oc-pages sends' do
    expect(Enums::Ci::Variable::TYPES).to include(unencrypted_var: 3)
    expect { build_variable('unencrypted_var') }.not_to raise_error
  end

  it 'stores an unencrypted variable in the clear, so it can be found by value' do
    variable = build_variable('unencrypted_var')

    expect(stored_value(variable)).to eq(url)
    expect(Ci::PipelineVariable.where(key: 'BLUEPRINT_PROJECT_URL', encrypted_value: url))
      .to include(variable)
  end

  it 'still encrypts an ordinary variable' do
    variable = build_variable('env_var')

    expect(stored_value(variable)).not_to eq(url)
    expect(variable.reload.value).to eq(url)
  end

  it 'encrypts anyway when the type is set after the value, which is the trap' do
    variable = build_variable('unencrypted_var', type_first: false)

    expect(stored_value(variable)).not_to eq(url)
  end
end
