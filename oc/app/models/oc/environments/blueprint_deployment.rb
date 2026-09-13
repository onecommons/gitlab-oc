# frozen_string_literal: true

module OC
  module Environments
    # OC Change -- one row per successful deployment of a blueprint.
    #
    # The same fact lives in the deployment pipeline's BLUEPRINT_PROJECT_URL
    # variable, but p_ci_pipeline_variables is indexed on (project_id) and
    # (pipeline_id, key, partition_id), so finding every pipeline carrying a
    # given value means scanning every variable ever written. The deploy badge
    # is public and unauthenticated, so that is not a query it can make.
    class BlueprintDeployment < ApplicationRecord
      self.table_name = 'oc_blueprint_deployments'

      belongs_to :blueprint_project, class_name: '::Project'
      belongs_to :deployed_project, class_name: '::Project'

      validates :finished_at, presence: true

      scope :for_blueprint, ->(project) { where(blueprint_project: project) }

      BLUEPRINT_URL_VARIABLE = 'BLUEPRINT_PROJECT_URL'

      # Records a finished deployment pipeline, if it names a blueprint here.
      #
      # The unique index on (deployed_project_id, finished_at) is what makes a
      # redelivered event a no-op: Ci::PipelineFinishedEvent is delivered at
      # least once, and a redelivery carries the same timestamp.
      def self.record_from(pipeline, root_url)
        blueprint = blueprint_for(blueprint_url(pipeline), root_url)
        return unless blueprint

        create!(blueprint_project: blueprint, deployed_project: pipeline.project,
          finished_at: pipeline.finished_at || Time.current)
      rescue ActiveRecord::RecordNotUnique
        nil
      end

      # Served by the unique index on (pipeline_id, key, partition_id). Read
      # through the model, so it works whether or not the variable was stored
      # in the clear.
      def self.blueprint_url(pipeline)
        pipeline.variables.find_by(key: BLUEPRINT_URL_VARIABLE)&.value
      end

      # The blueprint a deployment pipeline names, when it is a project here. A
      # blueprint on another instance has no local project and is not counted.
      def self.blueprint_for(url, root_url)
        return if url.blank?

        path = url.delete_prefix(root_url.to_s).delete_prefix('/').delete_suffix('.git')
        return if path.blank?

        # Bare `Project` inside module OC resolves to OC::Project.
        ::Project.find_by_full_path(path)
      end
    end
  end
end
