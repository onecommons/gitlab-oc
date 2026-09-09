# frozen_string_literal: true

module Resolvers
  class ProjectJobsResolver < BaseResolver
    include Gitlab::Graphql::Authorize::AuthorizeResource
    include LooksAhead

    type ::Types::Ci::JobType.connection_type, null: true
    authorize :read_build
    authorizes_object!
    extension ::Gitlab::Graphql::Limit::FieldCallCount, limit: 1

    argument :statuses, [::Types::Ci::JobStatusEnum],
      required: false,
      description: 'Filter jobs by status.'

    argument :with_artifacts, ::GraphQL::Types::Boolean,
      required: false,
      description: 'Filter by artifacts presence.'

    argument :name, GraphQL::Types::String,
      required: false,
      experiment: { milestone: '17.11' },
      description: 'Filter jobs by name.'

    argument :sources, [::Types::Ci::JobSourceEnum],
      required: false,
      experiment: { milestone: '17.7' },
      description: "Filter jobs by source."

    argument :kind, ::Types::Ci::JobKindEnum,
      required: false,
      description: 'Filter jobs by kind.'

    argument :pipeline_iid, GraphQL::Types::String,
      required: false,
      description: 'Filter jobs by the internal pipeline ID (iid).'

    # OC Change: a deployment page shows only its own jobs, matched on the
    # DEPLOY_PATH variable they carry.
    argument :var_deploy_path, GraphQL::Types::String,
      required: false,
      description: 'Filter jobs by their DEPLOY_PATH pipeline variable.'

    alias_method :project, :object

    # OC Change: matching var_deploy_path reads each build's variables, and the
    # predefined ones are derived from the commit, so the filtered path reaches
    # Gitaly. 15.11 carried this without knowing why.
    calls_gitaly!

    def resolve_with_lookahead(**args)
      @kind = args[:kind]
      @with_artifacts = args[:with_artifacts]

      filter_by_name = args[:name].to_s.present?
      filter_by_sources = args[:sources].present?

      jobs = ::Ci::JobsFinder.new(
        current_user: current_user, project: project, params: {
          scope: args[:statuses], with_artifacts: args[:with_artifacts],
          skip_ordering: filter_by_sources, pipeline_iid: args[:pipeline_iid],
          var_deploy_path: args[:var_deploy_path] # OC Change
        }, type: args[:kind] || ::Ci::Build
      ).execute

      # These job filters are currently exclusive with each other
      if filter_by_name
        jobs = ::Ci::BuildNameFinder.new(
          relation: jobs,
          name: args[:name],
          project: project
        ).execute
      elsif filter_by_sources
        jobs = ::Ci::BuildSourceFinder.new(
          relation: jobs,
          sources: args[:sources],
          project: project
        ).execute

        return offset_pagination(apply_lookahead(jobs))
      end

      apply_lookahead(jobs)
    end

    private

    def should_preload_artifacts?
      @with_artifacts || @kind == ::Ci::Build
    end

    def preloads
      base_preloads = {
        previous_stage_jobs_or_needs: [:needs, :pipeline],
        pipeline: [:user],
        job_source: [:source]
      }

      base_preloads[:artifacts] = [:job_artifacts] if should_preload_artifacts?

      base_preloads
    end
  end
end
