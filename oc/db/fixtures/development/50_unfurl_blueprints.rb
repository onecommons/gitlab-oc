# frozen_string_literal: true

# Imports Unfurl Cloud blueprints a development instance can deploy from:
#
#   bundle exec rake db:seed_fu FILTER=unfurl_blueprints
#
# Each is created under the same group path it has on unfurl.cloud and left
# public, so the Unfurl server can clone it anonymously. Imports run in the
# background; the projects are usable once Sidekiq has finished them.
require './spec/support/sidekiq_middleware'

Gitlab::Seeder.quiet do
  blueprints = %w[
    https://unfurl.cloud/onecommons/testing/smorgasbord.git
    https://unfurl.cloud/onecommons/testing/simple-blueprint.git
    https://unfurl.cloud/onecommons/blueprints/minecraft.git
  ]

  user = User.admins.first

  blueprints.each do |url|
    full_path = url.delete_prefix('https://unfurl.cloud/').delete_suffix('.git')
    group_path, _, project_path = full_path.rpartition('/')

    if Project.find_by_full_path(full_path)
      print 'S'
      next
    end

    group = Sidekiq::Worker.skipping_transaction_check do
      Group.find_by_full_path(group_path) || Groups::NestedCreateService.new(
        user, group_path: group_path, organization_id: user.organization.id,
        visibility_level: Gitlab::VisibilityLevel::PUBLIC
      ).execute
    end

    project = Projects::CreateService.new(user,
      import_url: url,
      namespace_id: group.id,
      path: project_path,
      name: project_path,
      visibility_level: Gitlab::VisibilityLevel::PUBLIC
    ).execute

    unless project.persisted?
      print "F(#{project.errors.full_messages.join(', ')})"
      next
    end

    # `spec/support/sidekiq_middleware` above requires `sidekiq/testing`, which
    # leaves Sidekiq in fake mode, so the queued import never runs and the
    # project is left with an empty repository. Import here instead: a seeded
    # blueprint nobody can deploy from is worse than no blueprint at all.
    state = project.import_state || project.create_import_state
    state.update!(status: 'scheduled') unless state.scheduled? || state.started?

    # seed-fu wraps the whole file in a transaction, and a finished import
    # enqueues DetectRepositoryLanguagesWorker, which that forbids.
    Sidekiq::Worker.skipping_transaction_check do
      RepositoryImportWorker.new.perform(project.id)
    end

    # Nothing classifies a project on a render path, so an unclassified
    # blueprint would import and then not look like one.
    project.refresh_unfurl_type!

    print project.reset.empty_repo? ? "F(#{project.import_state&.last_error || 'empty repository'})" : '.'
  end
end
