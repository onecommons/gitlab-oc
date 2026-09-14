# frozen_string_literal: true

module OC
  # Note that this makes a bare `Environment` inside module OC resolve here,
  # not to the upstream class.
  module Environment
    extend ActiveSupport::Concern

    prepended do
      has_one :unfurl_provider, class_name: 'OC::Environments::Provider',
        foreign_key: :environment_id, inverse_of: :environment
    end
  end
end
