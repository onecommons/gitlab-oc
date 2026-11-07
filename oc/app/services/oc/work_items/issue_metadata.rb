# frozen_string_literal: true

module OC
  module WorkItems
    # Labels and a milestone named by title in a file pushed to the sync branch
    # (a draft, an offline edit): found across the project's ancestor groups,
    # else created on the project -- what importing does -- if the user may.
    # Needs #project and #user.
    module IssueMetadata
      private

      # rubocop:disable Gitlab/Authz/PermissionCheck -- the abilities Labels:: and Milestones::FindOrCreateService check
      def label_problem(titles)
        missing = titles.find { |title| label_service(title).execute(find_only: true).nil? }
        return unless missing && !can?(:admin_label, project)

        "label #{missing.inspect} does not exist, and you cannot create labels"
      end

      def milestone_problem(title)
        return unless title
        return if existing_milestone(title) || can?(:admin_milestone, project)

        "milestone #{title.inspect} does not exist, and you cannot create milestones"
      end
      # rubocop:enable Gitlab/Authz/PermissionCheck

      def labels_for(titles)
        titles.filter_map { |title| label_service(title).execute }
      end

      def milestone_for(title)
        return unless title

        ::Milestones::FindOrCreateService.new(project, user, 'title' => title).execute
      end

      def existing_milestone(title)
        groups = project.group&.self_and_ancestors_ids
        ::Milestone.for_projects_and_groups([project.id], groups).find_by(title: title) # rubocop:disable CodeReuse/ActiveRecord -- Milestones::FindOrCreateService's own lookup
      end

      def label_service(title)
        ::Labels::FindOrCreateService.new(user, project, title: title, include_ancestor_groups: true)
      end

      def can?(ability, subject)
        Ability.allowed?(user, ability, subject)
      end
    end
  end
end
