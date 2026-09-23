# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "time"
require "timeout"
require "uri"

module SendRepute
  module Rails
    class Client
      ENDPOINT = URI("https://www.sendrepute.com/api/v1/classify").freeze
      MODELS = %w[thor theos athena odin freya hermes ares apollo].freeze
      CONFIDENCE = %w[low medium high].freeze
      RESULT_KEYS = %w[label spamProbability flaggedTermCount confidence reasons flaggedTerms analyzedFields modelVersion analyzedAt contentAudit].freeze
      MAX_REQUEST_BYTES = 1_048_576
      MAX_RESPONSE_BYTES = 1_048_576

      def initialize(configuration)
        @configuration = configuration
      end

      def classify(payload)
        request = Net::HTTP::Post.new(ENDPOINT.request_uri)
        request["Authorization"] = "Bearer #{@configuration.token}"
        request["Accept"] = "application/json"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(payload)
        raise RequestError, "request exceeds 1 MiB" if request.body.bytesize > MAX_REQUEST_BYTES

        status, response_body = Timeout.timeout(
          @configuration.total_timeout,
          RequestError,
          "classification exceeded total response deadline"
        ) { perform_request(request) }

        raise RequestError, "classification returned HTTP #{status}" unless status == 200

        validate_response(JSON.parse(response_body))
      rescue JSON::ParserError => e
        raise ResponseError, "invalid JSON response: #{e.message}"
      rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError => e
        raise RequestError, "classification request failed: #{e.class}"
      end

      private

      def perform_request(request)
        response_body = +""
        status = nil
        Net::HTTP.start(
          ENDPOINT.host,
          ENDPOINT.port,
          use_ssl: true,
          verify_mode: OpenSSL::SSL::VERIFY_PEER,
          open_timeout: @configuration.open_timeout,
          read_timeout: @configuration.read_timeout,
          write_timeout: @configuration.write_timeout
        ) do |http|
          http.request(request) do |response|
            status = response.code.to_i
            response.read_body do |chunk|
              response_body << chunk
              raise ResponseError, "response exceeds 1 MiB" if response_body.bytesize > MAX_RESPONSE_BYTES
            end
          end
        end
        [status, response_body]
      end

      def validate_response(value)
        unless exact_keys?(value, %w[requestId model result billing]) &&
               value["requestId"].is_a?(String) && value["requestId"].length.between?(1, 128) &&
               MODELS.include?(value["model"]) && value["result"].is_a?(Hash) && value["billing"].is_a?(Hash)
          raise ResponseError, "response does not match the classification envelope"
        end
        result = value["result"]
        unless result.keys.all? { |key| RESULT_KEYS.include?(key) }
          raise ResponseError, "result contains unknown fields"
        end
        probability = result["spamProbability"]
        unless finite_number?(probability) && probability.between?(0, 1)
          raise ResponseError, "result.spamProbability must be between 0 and 1"
        end
        unless %w[inbox spam].include?(result["label"]) &&
               CONFIDENCE.include?(result["confidence"]) &&
               reason_array?(result["reasons"]) &&
               string_array?(result["flaggedTerms"]) &&
               string_array?(result["analyzedFields"]) &&
               result["modelVersion"].is_a?(String) &&
               iso8601?(result["analyzedAt"])
          raise ResponseError, "result is missing required classification fields"
        end
        if result.key?("flaggedTermCount") && !nonnegative_integer?(result["flaggedTermCount"])
          raise ResponseError, "result.flaggedTermCount is invalid"
        end
        validate_content_audit(result["contentAudit"]) if result.key?("contentAudit")

        billing = value["billing"]
        unless exact_keys?(billing, %w[chargedMillicents replayed]) &&
               nonnegative_integer?(billing["chargedMillicents"]) &&
               [true, false].include?(billing["replayed"])
          raise ResponseError, "billing is missing required fields"
        end

        value
      end

      def validate_content_audit(audit)
        required = %w[score grade summary counts totalIssues criticalCount warningCount suggestionCount issues goodPractices inputTruncated]
        allowed = required + %w[homoglyphTerms]
        unless audit.is_a?(Hash) && required.all? { |key| audit.key?(key) } &&
               audit.keys.all? { |key| allowed.include?(key) } &&
               nonnegative_integer?(audit["score"]) && audit["score"] <= 100 &&
               %w[A B C D F].include?(audit["grade"]) &&
               %w[fix_critical fix_warnings review_suggestions looks_good].include?(audit["summary"]) &&
               audit_count?(audit["counts"]) &&
               %w[totalIssues criticalCount warningCount suggestionCount].all? { |key| nonnegative_integer?(audit[key]) } &&
               audit_issue_array?(audit["issues"]) &&
               good_practice_array?(audit["goodPractices"]) &&
               [true, false].include?(audit["inputTruncated"]) &&
               (!audit.key?("homoglyphTerms") ||
                 (string_array?(audit["homoglyphTerms"]) && audit["homoglyphTerms"].length <= 20 &&
                  audit["homoglyphTerms"].all? { |term| term.length <= 120 }))
          raise ResponseError, "result.contentAudit is invalid"
        end
      end

      def reason_array?(value)
        value.is_a?(Array) && value.all? do |reason|
          exact_keys?(reason, %w[signal detail weight]) &&
            reason["signal"].is_a?(String) && reason["detail"].is_a?(String) &&
            finite_number?(reason["weight"])
        end
      end

      def audit_count?(value)
        exact_keys?(value, %w[words links images triggerPhrases]) &&
          value.values.all? { |count| nonnegative_integer?(count) }
      end

      def audit_issue_array?(value)
        value.is_a?(Array) && value.length <= 50 && value.all? do |issue|
          exact_keys?(issue, %w[code category severity deduction evidence]) &&
            issue["code"].is_a?(String) &&
            %w[subject content links structure compliance].include?(issue["category"]) &&
            %w[critical warning suggestion].include?(issue["severity"]) &&
            nonnegative_integer?(issue["deduction"]) && issue["deduction"] <= 100 &&
            issue["evidence"].is_a?(String) && issue["evidence"].length <= 200
        end
      end

      def good_practice_array?(value)
        value.is_a?(Array) && value.length <= 20 && value.all? do |practice|
          exact_keys?(practice, %w[code category]) &&
            practice["code"].is_a?(String) &&
            %w[subject content links structure compliance].include?(practice["category"])
        end
      end

      def exact_keys?(value, keys)
        value.is_a?(Hash) && value.keys.sort == keys.sort
      end

      def finite_number?(value)
        value.is_a?(Numeric) && value.finite?
      end

      def nonnegative_integer?(value)
        finite_number?(value) && value >= 0 && value % 1 == 0
      end

      def string_array?(value)
        value.is_a?(Array) && value.all? { |item| item.is_a?(String) }
      end

      def iso8601?(value)
        value.is_a?(String) && Time.iso8601(value)
        true
      rescue ArgumentError
        false
      end
    end
  end
end
