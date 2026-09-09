# frozen_string_literal: true

module OC
  # Adds a `params[:unfurl_type]` filter over the project's classification
  # custom attribute (see OC::UNFURL_*).
  module ProjectsFinder
    extend ::Gitlab::Utils::Override

    UNFURL_TYPES = [::OC::UNFURL_BLUEPRINT, ::OC::UNFURL_DASHBOARD, ::OC::REGULAR_PROJECT].freeze

    private

    override :filter_projects
    def filter_projects(collection)
      by_unfurl_type(super)
    end

    # rubocop: disable CodeReuse/ActiveRecord -- custom attributes are the project's own key/value store
    def by_unfurl_type(collection)
      type = params[:unfurl_type]
      return collection unless UNFURL_TYPES.include?(type)

      collection.joins(:custom_attributes).where(custom_attributes: { key: 'unfurl_type', value: type })
    end
    # rubocop: enable CodeReuse/ActiveRecord
  end
end
