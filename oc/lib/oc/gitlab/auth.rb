# frozen_string_literal: true

module OC
  module Gitlab
    module Auth
      # No `override` here, deliberately. Upstream prepends this module twice --
      # once inside `class << self` (lib/gitlab/auth.rb:115) and once at the
      # bottom of the file -- so it lands in both ancestries while the method
      # exists only on the singleton. Override.verify! checks the module side,
      # finds no instance method and raises, which is what `rake
      # lint:static_verification` reports. The spec beside this calls the method
      # for real, so a rename upstream still fails loudly.
      #
      # An Unfurl deployment runs as a CI job and commits its results back to
      # the repository, so its job token needs to push. Upstream grants
      # build_push_code, which is not the same ability.
      def build_authentication_abilities
        super + [:push_code]
      end
    end
  end
end
