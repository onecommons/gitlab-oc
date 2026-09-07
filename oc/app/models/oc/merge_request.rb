# frozen_string_literal: true

module OC
  module MergeRequest
    extend ActiveSupport::Concern

    prepended do
      # See OC::Issue for why there is no `dependent:` here.
      has_one :oc_replica, class_name: 'OC::WorkItems::ReplicatedWorkItem', inverse_of: :merge_request
    end
  end
end
