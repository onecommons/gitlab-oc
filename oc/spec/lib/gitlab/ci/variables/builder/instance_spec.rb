# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gitlab::Ci::Variables::Builder::Instance, feature_category: :continuous_integration do
  let_it_be(:unprotected) { create(:ci_instance_variable, protected: false) }
  let_it_be(:protected_variable) { create(:ci_instance_variable, protected: true) }

  describe '#secret_variables' do
    def item(variable)
      Gitlab::Ci::Variables::Collection::Item.fabricate(variable)
    end

    it 'withholds an instance protected variable even from a protected ref' do
      variables = described_class.new.secret_variables(protected_ref: true)

      expect(variables).to contain_exactly(item(unprotected))
      expect(variables).not_to include(item(protected_variable))
    end
  end
end
