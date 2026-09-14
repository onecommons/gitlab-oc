# frozen_string_literal: true

# Imports the Unfurl Cloud repositories a development instance needs:
#
#   bundle exec rake db:seed_fu FILTER=unfurl_blueprints
#
# Each is created under the same group path it has on unfurl.cloud and left
# public, so the Unfurl server can clone it anonymously. Imports run in the
# background; the projects are usable once Sidekiq has finished them.
#
# `onecommons/std` is not a blueprint and nothing deploys from it. The
# dashboard's external-resource picker asks the Unfurl server for `/types`,
# which resolves the environment's declared repository by cloning it and
# reading its tags; without std that request fails and the picker offers
# nothing to add.
#
# `onecommons/cloudmap` is not one either: the sitemap links it. The cloud map
# page itself draws from the `UNFURL_CLOUDMAP_JSON` instance CI variable, which
# seeding the repository does not set.
#
# `onecommons/support` is where the dashboard's "Report Issue" action opens a
# new issue. It is created empty rather than imported: the real project serves
# its issues publicly but refuses a clone ("You are not allowed to download
# code from this project"), so an import fails and leaves nothing behind.
#
# `onecommons/ci` holds the pipeline every dashboard includes -- a dashboard's
# whole .gitlab-ci.yml is `include: project: onecommons/ci`. Without it no
# deployment can start: Ci::CreatePipelineService fails to resolve the include
# and the dashboard reports "Failed to trigger deployment".
require './spec/support/sidekiq_middleware'

Gitlab::Seeder.quiet do
  repositories = %w[
    https://unfurl.cloud/onecommons/testing/smorgasbord.git
    https://unfurl.cloud/onecommons/testing/simple-blueprint.git
    https://unfurl.cloud/onecommons/blueprints/minecraft.git
    https://unfurl.cloud/onecommons/std.git
    https://unfurl.cloud/onecommons/cloudmap.git
    https://unfurl.cloud/onecommons/ci.git
  ]

  user = User.admins.first

  find_or_create_group = ->(group_path) do
    Sidekiq::Worker.skipping_transaction_check do
      Group.find_by_full_path(group_path) || Groups::NestedCreateService.new(
        user, group_path: group_path, organization_id: user.organization.id,
        visibility_level: Gitlab::VisibilityLevel::PUBLIC
      ).execute
    end
  end

  repositories.each do |url|
    full_path = url.delete_prefix('https://unfurl.cloud/').delete_suffix('.git')
    group_path, _, project_path = full_path.rpartition('/')

    if Project.find_by_full_path(full_path)
      print 'S'
      next
    end

    group = find_or_create_group.call(group_path)

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
    # blueprint would import and then not look like one. std has neither
    # unfurl file, so this records it as an ordinary project.
    project.refresh_unfurl_type!

    print project.reset.empty_repo? ? "F(#{project.import_state&.last_error || 'empty repository'})" : '.'
  end

  support_path = 'onecommons/support'

  if Project.find_by_full_path(support_path)
    print 'S'
  else
    group_path, _, project_path = support_path.rpartition('/')

    project = Projects::CreateService.new(user,
      namespace_id: find_or_create_group.call(group_path).id,
      path: project_path,
      name: 'Support',
      description: 'Report a problem with this instance.',
      visibility_level: Gitlab::VisibilityLevel::PUBLIC
    ).execute

    print project.persisted? ? '.' : "F(#{project.errors.full_messages.join(', ')})"
  end
end
