# frozen_string_literal: true

module OC
  module Projects
    # A project with no avatar of its own gets an Unfurl placeholder rather
    # than GitLab's identicon. Keyed on the id's last digit, as in 15.11, so a
    # project carried across the upgrade keeps the placeholder it had.
    module UnfurlDefaultAvatar
      # Served from public/ rather than the asset pipeline, as the welcome
      # banner backgrounds are: a model has no request context to resolve a
      # digested asset path with.
      BASE_PATH = '/-/oc/assets/images'
      PLACEHOLDERS = [4, 1, 2, 3, 4, 5, 6, 1, 2, 3].map { |n| "#{BASE_PATH}/uf-avatar-placeholder-#{n}.svg" }.freeze

      def self.url_for(project, only_path: true)
        return unless project.id

        path = PLACEHOLDERS[project.id % PLACEHOLDERS.size]
        return path if only_path

        ::Gitlab::Utils.append_path(::Gitlab.config.gitlab.url, path)
      end
    end
  end
end
