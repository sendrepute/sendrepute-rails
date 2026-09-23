# frozen_string_literal: true

module SendRepute
  module Rails
    class Configuration
      MAX_TIMEOUT = 30
      MODES = %i[advisory block].freeze
      FAILURE_POLICIES = %i[preserve block].freeze

      attr_accessor :enabled, :paid_consent, :token, :mode, :failure_policy,
                    :score_threshold, :open_timeout, :read_timeout, :write_timeout, :total_timeout,
                    :on_result, :on_error, :client_factory

      def initialize
        @enabled = false
        @paid_consent = false
        @token = nil
        @mode = :advisory
        @failure_policy = :preserve
        @score_threshold = 0.8
        @open_timeout = 3
        @read_timeout = 5
        @write_timeout = 5
        @total_timeout = 10
        @on_result = nil
        @on_error = nil
        @client_factory = nil
      end

      def validate!
        raise ConfigurationError, "mode must be advisory or block" unless MODES.include?(mode)
        unless FAILURE_POLICIES.include?(failure_policy)
          raise ConfigurationError, "failure_policy must be preserve or block"
        end
        unless score_threshold.is_a?(Numeric) && score_threshold.between?(0, 1)
          raise ConfigurationError, "score_threshold must be between 0 and 1"
        end
        %i[open_timeout read_timeout write_timeout total_timeout].each do |name|
          value = public_send(name)
          raise ConfigurationError, "#{name} must be positive" unless value.is_a?(Numeric) && value.positive?
          raise ConfigurationError, "#{name} must not exceed #{MAX_TIMEOUT} seconds" if value > MAX_TIMEOUT
        end
        if enabled && !paid_consent
          raise ConfigurationError, "paid_consent must be true before enabling paid checks"
        end
        if enabled && (token.nil? || token.strip.empty?)
          raise ConfigurationError, "token is required when enabled"
        end
        self
      end

      def client
        validate!
        return client_factory.call(self) if client_factory

        Client.new(self)
      end
    end
  end
end
