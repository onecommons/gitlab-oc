# frozen_string_literal: true

FactoryBot.define do
  factory :oc_cloudmap_event, class: 'OC::Projects::CloudmapEvent' do
    project
    organization_id { project.organization_id }
    project_path { project.full_path }
    kind { :visibility_changed }
    occurred_at { Time.current }
    payload { { 'visibility_level' => ::Gitlab::VisibilityLevel::PRIVATE } }

    # What is left of a project that is gone: no record to point at, and the
    # path the only thing still naming it.
    trait :deletion do
      kind { :project_deleted }
      payload { {} }

      after(:build) do |event, evaluator|
        event.project_path = evaluator.project.full_path
        event.project = nil
      end
    end
  end
end
