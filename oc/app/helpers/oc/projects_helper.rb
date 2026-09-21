# frozen_string_literal: true

module OC
  module ProjectsHelper
    # A blueprint with no avatar gets an Unfurl placeholder rather than GitLab's
    # identicon. Mirrors placeholderAvatarUrl in
    # oc/app/assets/javascripts/explore/blueprints/constants.js -- keep the two
    # in step, or a blueprint's tile and its overview show different artwork.
    PLACEHOLDER_AVATARS = [4, 1, 2, 3, 4, 5, 6, 1, 2, 3].freeze

    def oc_placeholder_avatar_path(project)
      index = PLACEHOLDER_AVATARS[project.id % PLACEHOLDER_AVATARS.size]

      "/-/oc/assets/images/uf-avatar-placeholder-#{index}.svg"
    end
  end
end
