# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::Repositories::PullMirrors::Webhook::ManualService, feature_category: :source_code_management do
  let_it_be_with_reload(:project) do
    create(:project, import_url: 'https://git.example.test/team/source.git')
  end

  let(:service) { described_class.new(project) }

  def stored_token
    project.reload.import_data&.credentials&.dig(:webhook_token)
  end

  describe 'create' do
    it 'hands back the endpoint and a secret, and stores that same secret' do
      result = service.execute(:create)

      expect(result[:status]).to eq(:success)
      expect(result[:hook]).to match(
        url: "#{Settings.gitlab.url}/api/v4/projects/#{project.id}/mirror/fetch",
        secret: be_present,
        events: ['push']
      )
      expect(result[:hook][:secret]).to eq(stored_token)
    end

    it 'issues a new secret each time, so update rotates it' do
      first = service.execute(:create)[:hook][:secret]
      second = service.execute(:update)[:hook][:secret]

      expect(second).not_to eq(first)
      expect(stored_token).to eq(second)
    end
  end

  describe 'delete' do
    it 'clears the stored secret and does not hand one back' do
      service.execute(:create)
      expect(stored_token).to be_present

      result = service.execute(:delete)

      expect(result[:status]).to eq(:success)
      expect(result[:hook]).to eq(
        url: "#{Settings.gitlab.url}/api/v4/projects/#{project.id}/mirror/fetch",
        events: ['push']
      )
      expect(stored_token).to be_nil
    end
  end
end
