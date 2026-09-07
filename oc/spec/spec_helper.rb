# frozen_string_literal: true

Dir[Rails.root.join("oc/spec/support/helpers/*.rb")].each { |f| require f }
Dir[Rails.root.join("oc/spec/support/**/*.rb")].each { |f| require f }
