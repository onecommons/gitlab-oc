# frozen_string_literal: true

# OC Change #965 -- the public cloud map, drawn by the oc-pages public_cloud
# package from the cloudmap CI variable.
class PublicCloudController < ApplicationController
  skip_before_action :authenticate_user!

  feature_category :groups_and_projects

  def index; end

  private

  def cloudmap
    ::Ci::InstanceVariable.all_cached.find { |variable| variable.key == 'UNFURL_CLOUDMAP_JSON' }&.value
  end
  helper_method :cloudmap
end
