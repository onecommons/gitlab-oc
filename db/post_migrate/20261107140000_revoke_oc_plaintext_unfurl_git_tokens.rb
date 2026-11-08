# frozen_string_literal: true

# OC is an acronym inflection, so the OC prefix camelizes with it.
#
# GET /api/v4/unfurl_access_token used to keep each user's git token as
# "<id>|<token>" in a plain-text custom attribute. It now keeps it encrypted
# (oc_unfurl_git_tokens), so the old copies go: their tokens are revoked,
# having been readable in every dump and by admins through the API, and so no
# user is left with two live write tokens. They are not copied over. Only the
# id is read from each value, and nothing is logged.
class RevokeOCPlaintextUnfurlGitTokens < Gitlab::Database::Migration[2.3]
  milestone '19.3'
  # user_custom_attributes is gitlab_main_user and personal_access_tokens
  # gitlab_main_org; both are :gitlab_main to a migration.
  restrict_gitlab_migration gitlab_schema: :gitlab_main
  disable_ddl_transaction!

  BATCH_SIZE = 100
  ATTRIBUTE_KEY = 'unfurl_git_token'
  TOKEN_NAME = 'UNFURL_GIT_ACCESS'

  def up
    attributes = define_batchable_model(:user_custom_attributes, connection: connection)
    tokens = define_batchable_model(:personal_access_tokens, connection: connection)

    attributes.where(key: ATTRIBUTE_KEY).each_batch(of: BATCH_SIZE) do |batch|
      owners = batch.pluck(:user_id, :value).filter_map do |user_id, value|
        id = value.to_s.split('|', 2).first
        [id.to_i, user_id] if id.to_s.match?(/\A\d+\z/)
      end.to_h

      # Only a token of the user whose attribute named it, and only one this
      # endpoint made.
      revocable = tokens.where(id: owners.keys, name: TOKEN_NAME).pluck(:id, :user_id)
        .select { |id, user_id| owners[id] == user_id }.map(&:first)
      tokens.where(id: revocable).update_all(revoked: true, updated_at: Time.current) if revocable.any?

      batch.delete_all
    end
  end

  def down
    # Irreversible: the tokens were revoked, and their plain-text copies are gone.
  end
end
