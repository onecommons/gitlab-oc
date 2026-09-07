# frozen_string_literal: true

module OC
  module Gitlab
    module SidekiqConfig
      extend ActiveSupport::Concern

      class_methods do
        extend ::Gitlab::Utils::Override
        include ::Gitlab::Utils::StrongMemoize

        override :workers
        def workers
          super + oc_workers
        end

        # oc workers are neither EE nor JH, so `super` files them under FOSS.
        override :workers_for_all_queues_yml
        def workers_for_all_queues_yml
          foss_workers, ee_workers, jh_workers = super
          oc_workers, foss_workers = foss_workers.partition(&:oc?)

          [foss_workers, ee_workers, jh_workers, oc_workers]
        end

        override :all_queues_yml_outdated?
        def all_queues_yml_outdated?
          return true if super
          return false unless ::Gitlab.oc?

          workers_for_all_queues_yml.last != YAML.load_file(::Gitlab::SidekiqConfig::OC_QUEUE_CONFIG_PATH)
        end

        private

        def oc_workers
          find_workers(Rails.root.join('oc/app/workers'), ee: false, jh: false, oc: true)
        end
        strong_memoize_attr :oc_workers
      end
    end
  end
end
