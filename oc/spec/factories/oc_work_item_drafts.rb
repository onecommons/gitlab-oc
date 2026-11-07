# frozen_string_literal: true

FactoryBot.define do
  factory :oc_work_item_draft, class: 'OC::WorkItems::Draft' do
    project
    issue { association :issue, project: project }
    sequence(:key) { |n| "draft-#{n}" }
    iid { issue&.iid || 1 }
  end
end
