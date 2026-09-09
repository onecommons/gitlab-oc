# frozen_string_literal: true

# OC Change -- the fork's public surface: verified blueprints, the cloud map
# and the Unfurl libraries. EE's SitemapController never loads in this edition.
class SitemapController < ApplicationController
  skip_before_action :authenticate_user!

  feature_category :groups_and_projects

  def show
    @projects = verified_blueprints
    @std = ::Project.find_by_full_path(OC::UNFURL_STD_PROJECT)
    @cloudmap = ::Project.find_by_full_path(OC::UNFURL_CLOUDMAP_PROJECT)

    respond_to do |format|
      format.xml { render formats: [:xml], handlers: [:haml] }
    end
  end

  private

  def verified_blueprints
    ::ProjectsFinder.new(
      current_user: nil,
      params: { unfurl_type: OC::UNFURL_BLUEPRINT, namespace_path: OC::BLUEPRINTS_GROUP, non_archived: true }
    ).execute
  end

  def location(project)
    URI.join(::Gitlab.config.gitlab.url, project.full_path).to_s
  end
  helper_method :location

  def last_modified(record)
    record&.last_repository_updated_at&.strftime('%Y-%m-%d')
  end
  helper_method :last_modified

  def newest(projects)
    projects.compact.max_by { |project| project.last_repository_updated_at || Time.at(0).utc }
  end
  helper_method :newest
end
