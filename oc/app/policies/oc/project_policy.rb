# frozen_string_literal: true

module OC
  module ProjectPolicy
    extend ActiveSupport::Concern

    prepended do
      # Classification writes, and a policy is evaluated on render paths and on
      # projects that were never saved, so this reads what the classifier last
      # stored rather than working it out.
      desc 'project is an unfurl dashboard'
      condition(:unfurl_dashboard, scope: :subject) do
        subject.recorded_unfurl_type == ::OC::UNFURL_DASHBOARD
      end

      # A dashboard exists to show what is deployed, so anyone who can see the
      # project can see its environments and deployments -- including
      # anonymously, which is how a public dashboard is meant to read. Upstream
      # ties both to builds, which a dashboard has no reason to expose.
      rule { can?(:read_project) & unfurl_dashboard }.policy do
        enable :read_environment
        enable :read_deployment
      end

      rule { ~can?(:read_project) & unfurl_dashboard }.policy do
        prevent :read_environment
        prevent :read_deployment
      end

      # What upstream prevents in the same block these two were lifted out of.
      rule { (builds_disabled & ~unfurl_dashboard) | repository_disabled }.policy do
        prevent :read_environment
        prevent :read_deployment
      end
    end
  end
end
