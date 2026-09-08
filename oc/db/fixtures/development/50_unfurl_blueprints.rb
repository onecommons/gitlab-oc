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

    print project.persisted? ? '.' : "F(#{project.errors.full_messages.join(', ')})"
  end
end
