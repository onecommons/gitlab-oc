# frozen_string_literal: true

module OC
  # rubocop:disable Gitlab/BoundedContexts -- the name has to match the class this
  # prepends. The cop recognises the EE:: and JH:: prefixes and allows their
  # equivalent (ee/app/models/ee/personal_access_token.rb passes); it does not
  # know OC::, so a fork override only passes when the class it extends happens
  # to name a bounded context.
  module PersonalAccessToken
    extend ActiveSupport::Concern
    extend ::Gitlab::Utils::Override

    private

    # 19.3 requires an expiry unless the instance setting says otherwise. The
    # deployment token is machine-to-machine and nothing renews it, so a year
    # from creation is a year until every dashboard's deployments start failing.
    override :allow_expires_at_to_be_empty?
    def allow_expires_at_to_be_empty?
      super || name == ::OC::PROJECT_TOKEN_NAME
    end
  end
end
# rubocop:enable Gitlab/BoundedContexts
