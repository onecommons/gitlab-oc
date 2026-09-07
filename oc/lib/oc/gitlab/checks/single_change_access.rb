# frozen_string_literal: true

module OC
  module Gitlab
    module Checks
      # Adds the sync.yml check to the ref-level checks every push runs.
      #
      # A ref-level check rather than a commit one: what matters is the file as
      # the push leaves it, not what happened to it along the way. A branch
      # whose intermediate commits each broke the file differently is a normal
      # thing to push, and reviewing them one by one would refuse it for
      # problems the push does not actually leave behind.
      module SingleChangeAccess
        protected

        def ref_level_checks
          super

          ::OC::Gitlab::Checks::SyncFileCheck.new(self).validate!
        end
      end
    end
  end
end
