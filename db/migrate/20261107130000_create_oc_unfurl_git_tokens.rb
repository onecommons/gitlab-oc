# frozen_string_literal: true

# The git token each user (or the cloudmap's project bot) hands the Unfurl
# server, kept encrypted so a database dump does not hold live write tokens.
class CreateOCUnfurlGitTokens < Gitlab::Database::Migration[2.3]
  milestone '19.3'

  def change
    create_table :oc_unfurl_git_tokens do |t|
      t.references :user, null: false, index: { unique: true },
        foreign_key: { to_table: :users, on_delete: :cascade }

      # No foreign key: personal_access_tokens is in another schema. A missing
      # token is replaced on the next request.
      t.bigint :personal_access_token_id, null: false

      t.timestamps_with_timezone null: false

      # Encrypted (`encrypts :token`), so never the token itself. Text rather
      # than jsonb: the ciphertext has no shape a JSON schema could check.
      t.text :token, null: false, limit: 2048
    end
  end
end
