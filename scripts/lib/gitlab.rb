# frozen_string_literal: true

module Gitlab
  module_function

  def ee?
    File.exist?(File.expand_path('../../ee/app/models/license.rb', __dir__)) && !%w[true 1].include?(ENV['FOSS_ONLY'].to_s) && !oc? # rubocop:disable Rails/NegateInclude -- OC Change: never EE in the oc edition
  end

  def jh?
    ee? && Dir.exist?(File.expand_path('../../jh', __dir__)) && !%w[true 1].include?(ENV['EE_ONLY'].to_s) # rubocop:disable Rails/NegateInclude
  end

  # OC Change
  def oc?
    Dir.exist?(File.expand_path('../../oc', __dir__)) && !%w[true 1].include?(ENV['GITLAB_ONLY'].to_s) # rubocop:disable Rails/NegateInclude
  end
end
