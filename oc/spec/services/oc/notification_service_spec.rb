# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NotificationService, feature_category: :system_access do
  let_it_be(:user) { create(:user) }

  describe '#access_token_created' do
    it 'stays quiet about the token Unfurl creates on the user behalf' do
      expect(Notify).not_to receive(:access_token_created_email)

      described_class.new.access_token_created(user, OC::GIT_TOKEN_NAME)
    end

    it 'still announces a token the user asked for' do
      expect(Notify).to receive(:access_token_created_email).with(user, 'my token').and_call_original

      described_class.new.access_token_created(user, 'my token')
    end
  end
end
