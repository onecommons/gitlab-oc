# frozen_string_literal: true

# Rebuilds the vendored Unfurl template archives, replacing the manual export
# in cloud-dev-ensemble's project-templates/README.md. The blueprint templates
# are links to their projects and are not vendored.
namespace :gitlab do
  namespace :oc do
    desc 'GitLab | OC | Rebuild the vendored Unfurl project template archives'
    task :update_project_templates, [] => :environment do |_task, args|
      # The archives exist to carry these two settings into every project made
      # from them.
      visibility = {
        'unfurl_dashboard' => Gitlab::VisibilityLevel::PRIVATE,
        'unfurl_testbed' => Gitlab::VisibilityLevel::INTERNAL
      }

      raise 'This rake task is not meant for production instances' if Rails.env.production?

      requested = args.extras
      names = requested.empty? ? visibility.keys : visibility.keys & requested
      raise "Nothing to rebuild. Known templates: #{visibility.keys.join(', ')}" if names.empty?

      admin = User.admins.first
      raise 'No admin user could be found' unless admin

      # download_or_copy_upload is private, and copes with object storage as well
      # as the local disk a GDK uses.
      downloader = Class.new { include Gitlab::ImportExport::CommandLineUtil }.new

      organization_path = "tmp-oc-templates-#{SecureRandom.hex(4)}"
      puts "Creating temporary organization #{organization_path}"
      organization = ::Organizations::Organization.create!(name: organization_path, path: organization_path)

      namespace_path = "tmp-oc-templates-#{Time.now.to_i}"
      puts "Creating temporary namespace #{namespace_path}"
      namespace = Namespace.create!(
        owner: admin,
        name: namespace_path,
        path: namespace_path,
        type: Namespaces::UserNamespace.sti_name,
        organization: organization
      )

      names.each do |name|
        template = Gitlab::ProjectTemplate.find(name)

        puts "Creating project for #{template.title}"
        project = Projects::CreateService.new(admin, {
          namespace_id: namespace.id,
          organization_id: organization.id,
          path: name,
          visibility_level: visibility.fetch(name),
          default_branch: 'main',
          skip_wiki: true
        }).execute

        raise "Failed to create project: #{project.errors.messages}" unless project.persisted?

        project.ci_cd_settings.update!(forward_deployment_enabled: false)

        Dir.mktmpdir do |tmpdir|
          source = File.join(tmpdir, 'source')
          Gitlab::TaskHelpers.run_command!(
            %W[git clone --quiet --depth 1 --branch main #{template.clone_url} #{source}]
          )

          actions = Dir.glob('**/*', File::FNM_DOTMATCH, base: source).sort.filter_map do |path|
            next if path.start_with?('.git/') || path == '.git' || File.directory?(File.join(source, path))

            {
              action: :create,
              file_path: path,
              content: Base64.strict_encode64(File.binread(File.join(source, path))),
              encoding: 'base64',
              execute_filemode: File.executable?(File.join(source, path))
            }
          end

          # A single commit, as the vendored archives have always carried.
          project.repository.commit_files(
            admin,
            branch_name: 'main',
            message: "Exported from #{template.preview}/-/tree/main",
            actions: actions
          )
        end

        project.reset

        Projects::ImportExport::ExportService.new(project, admin).execute
        downloader.send(:download_or_copy_upload, project.export_file(admin), template.archive_path)

        puts "Exported #{name} to #{template.archive_path}".green

        next if Projects::DestroyService.new(project, admin).execute

        puts "Failed to destroy project #{name} (the namespace is cleaned up below)"
      end
    ensure
      if namespace
        puts "Destroying temporary namespace #{namespace_path}"
        namespace.destroy
      end

      if organization
        puts "Destroying temporary organization #{organization_path}"
        organization.users.delete_all
        organization.destroy
      end
    end
  end
end
