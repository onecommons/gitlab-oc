# frozen_string_literal: true

module Enums # rubocop: disable Gitlab/BoundedContexts -- It's within CI domain
  module Ci
    module Variable
      TYPES = {
        env_var: 1,
        file: 2,
        # OC Change -- a variable the fork needs to query by value, so it is
        # stored in the clear. See Ci::HasVariable#should_encrypt?.
        unencrypted_var: 3
      }.freeze
    end
  end
end
