# frozen_string_literal: true

require "active_support/concern"

module SendRepute
  module Rails
    module Mailer
      extend ActiveSupport::Concern

      included do
        before_deliver :sendrepute_before_deliver
      end

      # Call only inside a mailer action whose message the user explicitly chose
      # to submit to the paid service. Do not call this for security/account mail.
      def sendrepute_paid_preflight!
        @sendrepute_paid_preflight = true
      end

      private

      def sendrepute_before_deliver
        configuration = SendRepute::Rails.configuration
        return unless configuration.enabled && configuration.paid_consent
        return unless @sendrepute_paid_preflight

        response = configuration.client.classify(Message.payload(message))
        should_block = configuration.mode == :block &&
                       response.dig("result", "spamProbability") >= configuration.score_threshold
        safe_callback(configuration.on_result, deep_freeze(response))
        throw(:abort) if should_block
      rescue StandardError => e
        safe_callback(configuration&.on_error, e)
        throw(:abort) if configuration&.failure_policy == :block
      end

      def safe_callback(callback, argument)
        catch(:abort) { callback&.call(argument) }
      rescue StandardError
        nil
      end

      def deep_freeze(value)
        value.each { |key, item| deep_freeze(key); deep_freeze(item) } if value.is_a?(Hash)
        value.each { |item| deep_freeze(item) } if value.is_a?(Array)
        value.freeze
      end
    end
  end
end
