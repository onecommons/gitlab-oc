# frozen_string_literal: true

# OC Change -- filter jobs by their CI variables, so a deployment page can show
# only the jobs belonging to it. `?var_foo_path=bar` matches jobs whose
# FOO_PATH variable is 'bar'.
module OC
  module Ci
    module JobsFinder
      extend ::Gitlab::Utils::Override

      override :filter_builds
      def filter_builds(builds)
        filter_by_variable(super)
      end

      private

      def filter_by_variable(builds)
        filters = variable_filters
        return builds if filters.empty?

        matching = builds.select do |build|
          filters.all? { |key, value| build.variables[key]&.value == value }
        end

        return type.none if matching.empty?

        # p_ci_builds is partitioned, so the lookup names both key columns.
        # Ids come from a single sequence, so the partition list only prunes.
        # rubocop: disable CodeReuse/ActiveRecord -- turning a Ruby select back into a relation
        builds.where(id: matching.map(&:id), partition_id: matching.map(&:partition_id))
        # rubocop: enable CodeReuse/ActiveRecord
      end

      # ActionController::Parameters will not #to_h unpermitted keys, and the
      # keys are not knowable ahead of time to permit them; as_json does.
      def variable_filters
        params.select { |key, _| key.to_s.start_with?('var_') }
          .transform_keys { |key| key.to_s.delete_prefix('var_').upcase }
          .as_json
      end
    end
  end
end
