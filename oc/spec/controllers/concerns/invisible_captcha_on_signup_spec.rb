# frozen_string_literal: true

require 'spec_helper'

RSpec.describe InvisibleCaptchaOnSignup, feature_category: :system_access do
  # #672 -- an invite code proves a human well enough, and the end-to-end suite
  # fills the form faster than the honeypot allows.
  describe '#on_honeypot_spam_callback' do
    let(:controller) { RegistrationsController.new }

    before do
      create(:ci_instance_variable, key: OC::Onboarding::InviteCodes::VALID_KEY, value: 'friend-1')
      stub_application_setting(invisible_captcha_enabled: true)
      allow(controller).to receive(:invite_code).and_return(code)
    end

    context 'with a code we issued' do
      let(:code) { 'friend-1' }

      it 'lets the signup through' do
        expect(controller).not_to receive(:head)

        controller.on_honeypot_spam_callback
      end
    end

    context 'with anything else' do
      let(:code) { 'not-ours' }

      it 'leaves the honeypot to upstream' do
        allow(controller).to receive(:log_request)
        expect(controller).to receive(:head).with(:ok)

        controller.on_honeypot_spam_callback
      end
    end
  end
end
