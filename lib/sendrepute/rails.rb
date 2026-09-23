# frozen_string_literal: true

require "action_mailer"
require_relative "rails/version"
require_relative "rails/configuration"
require_relative "rails/client"
require_relative "rails/message"
require_relative "rails/mailer"

module SendRepute
  module Rails
    class Error < StandardError; end
    class ConfigurationError < Error; end
    class UnsupportedMessageError < Error; end
    class RequestError < Error; end
    class ResponseError < Error; end

    class << self
      attr_writer :configuration

      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration)
        configuration.validate!
      end

      def reset_configuration!
        @configuration = Configuration.new
      end
    end
  end
end
