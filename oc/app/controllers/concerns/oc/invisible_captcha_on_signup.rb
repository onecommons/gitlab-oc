# frozen_string_literal: true

module OC
  module InvisibleCaptchaOnSignup
    extend ActiveSupport::Concern
    extend ::Gitlab::Utils::Override

    # #672 -- an invite code is enough to prove a human, and the end-to-end
    # suite signs up faster than the honeypot's timestamp allows.
    override :on_honeypot_spam_callback
    def on_honeypot_spam_callback
      return if ::OC::Onboarding::InviteCodes.valid?(invite_code)

      super
    end
  end
end
