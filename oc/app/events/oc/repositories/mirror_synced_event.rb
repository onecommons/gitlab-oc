# frozen_string_literal: true

module OC
  module Repositories
    # OC Change -- a pull mirror moved a ref.
    #
    # `fetch_as_mirror` fires no hook and creates no Event row, so a mirror
    # sync is invisible to every timestamp on `projects` and to the activity
    # feed. This is the only announcement it makes.
    #
    # One ref, because that is all either call site tracks. Force mode also
    # deletes local-only branches without reporting them
    # (FetchRemote returns only TagsChanged and RepoChanged), so a row says
    # what moved and cannot say what went -- see
    # .ai/pull-mirror-sync-modes.md, whose per-branch classification is what
    # would fix that.
    class MirrorSyncedEvent < ::Gitlab::EventStore::Event
      def schema
        {
          'type' => 'object',
          'required' => %w[project_id ref new_sha],
          'properties' => {
            'project_id' => { 'type' => 'integer' },
            'ref' => { 'type' => 'string' },
            'old_sha' => { 'type' => %w[string null] },
            'new_sha' => { 'type' => 'string' }
          }
        }
      end
    end
  end
end
