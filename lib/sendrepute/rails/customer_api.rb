# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "openssl"
require "timeout"
require "uri"

module SendRepute
  module Rails
    # Programmatic client and policy for all 49 operations of the SendRepute
    # customer API (generated from artifacts/api-server/src/customer-api-openapi.json).
    module CustomerApi
      RESOURCE_DIR = File.expand_path("customer_api", __dir__)
      MAX_BODY_BYTES = 524_288
      QUOTE_TTL_SECONDS = 900
      PRICE_KEYS = %w[expectedPriceMillicents priceMillicents quotedPriceMillicents totalPriceMillicents chargeMillicents maximumChargeMillicents amountMillicents].freeze

      class PolicyError < StandardError
        attr_reader :status, :code

        def initialize(status, code, message)
          super(message)
          @status = status
          @code = code
        end
      end

      class ApiError < StandardError
        attr_reader :code, :status

        def initialize(code, message, status = 0)
          super(message)
          @code = code
          @status = status
        end
      end

      module Catalog
        module_function

        def data
          @data ||= JSON.parse(File.read(File.join(RESOURCE_DIR, "customer-api-operations.json"))).freeze
        end

        def operations
          data["operations"]
        end

        def get(id)
          operations.find { |op| op["id"] == id }
        end

        def quote_operation?(id)
          operations.any? { |op| op["quote"] == id }
        end
      end

      module Policy
        module_function

        # Returns { op:, method:, path:, body: } or raises PolicyError.
        def prepare(operation_id, input = {}, options = {})
          op = Catalog.get(operation_id.to_s)
          raise PolicyError.new(404, "UNKNOWN_OPERATION", "Operation is not part of the customer API catalog") unless op
          if options[:enabled].is_a?(Array) && !options[:enabled].include?(op["id"])
            raise PolicyError.new(403, "OPERATION_DISABLED", "Operation is disabled on this server")
          end

          input = stringify(input || {})
          params = input["params"] || {}
          query = input["query"] || {}
          raise PolicyError.new(400, "INVALID_INPUT", "params and query must be objects") unless params.is_a?(Hash) && query.is_a?(Hash)

          defs = op["params"] || []
          params.each_key { |k| raise PolicyError.new(400, "UNKNOWN_PARAMETER", "Unknown path parameter #{k}") unless defs.any? { |d| d["in"] == "path" && d["name"] == k } }
          query.each_key { |k| raise PolicyError.new(400, "UNKNOWN_PARAMETER", "Unknown query parameter #{k}") unless defs.any? { |d| d["in"] == "query" && d["name"] == k } }

          path = op["path"].dup
          search = []
          defs.each do |d|
            value = (d["in"] == "path" ? params : query)[d["name"]]
            if value.nil? || value == ""
              raise PolicyError.new(400, "MISSING_PARAMETER", "#{d['name']} is required") if d["in"] == "path"

              next
            end
            value = check_param(d, value)
            if d["in"] == "path"
              path = path.sub("{#{d['name']}}", URI.encode_www_form_component(value).gsub("+", "%20"))
            else
              search << [d["name"], value]
            end
          end

          body = nil
          if op["hasBody"]
            body = input["body"] || {}
            raise PolicyError.new(400, "INVALID_BODY", "Request body must be a JSON object") unless body.is_a?(Hash)

            body.each_key { |k| raise PolicyError.new(400, "UNKNOWN_FIELD", "Unsupported body field #{k}") unless op["bodyFields"].include?(k) }
            if op["id"] == "customerCreateVipEmailTemplate" && body["imageUrls"].is_a?(Array) && !body["imageUrls"].empty?
              raise PolicyError.new(400, "URLS_REFUSED", "imageUrls are refused by this integration; arbitrary URLs are not forwarded")
            end
            if op["handoff"]
              origin = options[:handoff_return_origin]
              raise PolicyError.new(403, "HANDOFF_NOT_CONFIGURED", "Hosted builder handoff requires a configured return origin") if origin.nil? || origin == ""
              if body["returnOrigin"] && body["returnOrigin"] != "" && body["returnOrigin"] != origin
                raise PolicyError.new(400, "RETURN_ORIGIN_FIXED", "returnOrigin is fixed by server configuration")
              end

              body["returnOrigin"] = origin
            end
          elsif !input["body"].nil?
            raise PolicyError.new(400, "UNEXPECTED_BODY", "This operation does not accept a request body")
          end

          if op["paid"]
            consent = stringify(options[:paid_consent])
            classification = op["id"] == CLASSIFY_OPERATION
            unless consent.is_a?(Hash) && consent["acknowledged"] == true
              raise PolicyError.new(428, "CONSENT_REQUIRED", "Paid operation requires explicit consent to an expected price in millicents")
            end
            auth = classification ? classification_authorization(consent, body) : nil
            unless classification || (consent["expectedPriceMillicents"].is_a?(Integer) && consent["expectedPriceMillicents"] >= 0)
              raise PolicyError.new(428, "CONSENT_REQUIRED", "Paid operation requires explicit consent to an expected price in millicents")
            end

            price = consent["expectedPriceMillicents"]
            if options[:require_quote]
              quoted_at = options[:quoted_at]
              now = options[:now] || Time.now.to_i
              unless quoted_at.is_a?(Integer) && now - quoted_at <= QUOTE_TTL_SECONDS
                raise PolicyError.new(428, "QUOTE_REQUIRED", "Run #{op['quote']} in this session within 15 minutes before this paid operation")
              end
            end
            if classification
              # Console: the confirmed schedule must equal the rates the server returned to this session's latest quote.
              if options.key?(:expected_pricing) && !same_rates?(options[:expected_pricing], auth["expectedPricing"])
                raise PolicyError.new(409, "PRICE_CONFIRMATION_STALE", "The confirmed rates no longer match the latest GET /v1/pricing result in this session. Load current rates and confirm again.")
              end
              # The server re-checks the schedule and ceiling atomically at settlement.
              body["priceAuthorization"] = auth
            elsif op["priceField"]
              parts = op["priceField"].split(".")
              target = body
              parts[0...-1].each do |part|
                raise PolicyError.new(400, "PRICE_AUTHORIZATION_REQUIRED", "#{parts[0...-1].join('.')} must be supplied for this paid operation") unless target[part].is_a?(Hash)

                target = target[part]
              end
              current = target[parts.last]
              if current.nil? || current == ""
                target[parts.last] = price
              elsif current != price
                raise PolicyError.new(409, "PRICE_MISMATCH", "#{op['priceField']} differs from the consented price")
              end
            end
            body[op["consentFlag"]] = true if op["consentFlag"]
          end
          if op["financial"] && options[:confirm] != true
            raise PolicyError.new(428, "CONFIRMATION_REQUIRED", "This billing or recovery action requires explicit confirmation")
          end

          serialized = nil
          if op["hasBody"]
            serialized = JSON.generate(body)
            raise PolicyError.new(413, "BODY_TOO_LARGE", "Request body exceeds 512 KiB") if serialized.bytesize > MAX_BODY_BYTES
          end
          qs = URI.encode_www_form(search)
          { op: op, method: op["method"], path: qs.empty? ? path : "#{path}?#{qs}", body: serialized }
        end

        CLASSIFY_OPERATION = "classifyCustomerEmail"
        CLASSIFICATION_RATE_FIELDS = %w[classificationBaseMillicents includedUniqueTerms additionalTermMillicents maximumClassificationMillicents].freeze

        # The four effective classification rates from a GET /v1/pricing response, or nil.
        def classification_rates(data)
          return nil unless data.is_a?(Hash)

          CLASSIFICATION_RATE_FIELDS.to_h do |f|
            v = data[f]
            return nil unless v.is_a?(Integer) && v >= 0

            [f, v]
          end
        end

        def same_rates?(a, b)
          a.is_a?(Hash) && b.is_a?(Hash) && CLASSIFICATION_RATE_FIELDS.all? { |f| a[f] == b[f] }
        end

        def strict_authorization?(v)
          v.is_a?(Hash) && v.size == 2 && v["expectedPricing"].is_a?(Hash) && v["expectedPricing"].size == 4 &&
            classification_rates(v["expectedPricing"]) && v["maxChargeMillicents"].is_a?(Integer) && v["maxChargeMillicents"] >= 0
        end

        # Exact CustomerClassificationPriceAuthorization: full rate schedule plus ceiling.
        def classification_authorization(consent, body)
          supplied = body["priceAuthorization"]
          missing = PolicyError.new(428, "CONSENT_REQUIRED", "Classification consent needs the four effective rates from GET /v1/pricing and a maximum charge in millicents")
          if consent.key?("expectedPricing") || consent.key?("maxChargeMillicents")
            ep = consent["expectedPricing"]
            rates = ep.is_a?(Hash) && ep.size == 4 ? classification_rates(ep) : nil
            raise missing unless rates && consent["maxChargeMillicents"].is_a?(Integer) && consent["maxChargeMillicents"] >= 0

            auth = { "expectedPricing" => rates, "maxChargeMillicents" => consent["maxChargeMillicents"] }
          elsif consent["expectedPriceMillicents"].is_a?(Integer) && consent["expectedPriceMillicents"] >= 0 && strict_authorization?(supplied)
            auth = { "expectedPricing" => classification_rates(supplied["expectedPricing"]), "maxChargeMillicents" => supplied["maxChargeMillicents"] }
            raise PolicyError.new(409, "PRICE_MISMATCH", "priceAuthorization.maxChargeMillicents differs from the consented price") unless auth["maxChargeMillicents"] == consent["expectedPriceMillicents"]
          else
            raise missing
          end
          unless supplied.nil? || (strict_authorization?(supplied) && same_rates?(supplied["expectedPricing"], auth["expectedPricing"]) && supplied["maxChargeMillicents"] == auth["maxChargeMillicents"])
            raise PolicyError.new(409, "PRICE_MISMATCH", "body.priceAuthorization differs from the consented rates or ceiling")
          end
          auth
        end

        def extract_quoted_price(data, depth = 0)
          return nil if depth > 4

          if data.is_a?(Hash)
            PRICE_KEYS.each { |k| return data[k] if data[k].is_a?(Integer) }
            data.each_value { |v| (found = extract_quoted_price(v, depth + 1)) && (return found) }
          elsif data.is_a?(Array)
            data.each { |v| (found = extract_quoted_price(v, depth + 1)) && (return found) }
          end
          nil
        end

        def stringify(value)
          case value
          when Hash then value.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify(v) }
          when Array then value.map { |v| stringify(v) }
          else value
          end
        end

        def check_param(d, value)
          if %w[integer number].include?(d["type"])
            value = value.to_i if value.is_a?(String) && value.match?(/\A\d{1,15}\z/)
            raise PolicyError.new(400, "INVALID_PARAMETER", "#{d['name']} must be a whole number") unless value.is_a?(Integer)
            raise PolicyError.new(400, "INVALID_PARAMETER", "#{d['name']} is below the minimum") if d["minimum"] && value < d["minimum"]
            raise PolicyError.new(400, "INVALID_PARAMETER", "#{d['name']} exceeds the maximum") if d["maximum"] && value > d["maximum"]

            return value.to_s
          end
          if !value.is_a?(String) || value.empty? || value.bytesize > (d["maxLength"] || 128) || value.match?(/[\r\n\0]/)
            raise PolicyError.new(400, "INVALID_PARAMETER", "#{d['name']} is invalid")
          end
          raise PolicyError.new(400, "INVALID_PARAMETER", "#{d['name']} is not an allowed value") if d["enum"] && !d["enum"].include?(value)
          if d["pattern"] && !Regexp.new(d["pattern"]).match?(value)
            raise PolicyError.new(400, "INVALID_PARAMETER", "#{d['name']} has an invalid format")
          end

          value
        end
      end

      # Fixed-origin HTTPS client. No retries, no redirects, bounded responses.
      class Client
        DEFAULT_BASE_URL = "https://www.sendrepute.com/api"

        def initialize(api_key:, base_url: DEFAULT_BASE_URL, trusted_hosts: [], timeout: 20, max_response_bytes: 8_388_608, transport: nil)
          raise ApiError.new("configuration", "A SendRepute customer API key is required.") unless api_key.is_a?(String) && api_key.match?(%r{\A[A-Za-z0-9._~+/=-]{16,512}\z})

          uri = URI(base_url.to_s.chomp("/"))
          hosts = ["www.sendrepute.com", *trusted_hosts].map(&:downcase)
          unless uri.is_a?(URI::HTTPS) && hosts.include?(uri.host.to_s.downcase) && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
            raise ApiError.new("configuration", "Customer API base URL must be HTTPS on an exact trusted host.")
          end
          raise ApiError.new("configuration", "timeout or response limit out of range") unless timeout.between?(1, 120) && max_response_bytes.between?(1024, 16_777_216)

          @api_key = api_key
          @base = uri
          @timeout = timeout
          @max = max_response_bytes
          @transport = transport || method(:net_http)
        end

        # One-way identity of the configured credential, used to scope durable intents.
        def credential_fingerprint
          Digest::SHA256.hexdigest("sendrepute-credential-v1\n#{@api_key}")
        end

        def inspect
          "#<#{self.class.name} base=#{@base}>"
        end
        alias to_s inspect

        def call(operation_id, input = {}, options = {})
          send_prepared(Policy.prepare(operation_id, input, options))
        end

        Catalog.operations.each do |op|
          define_method(op["id"]) { |input = {}, options = {}| call(op["id"], input, options) }
        end

        def send_prepared(prepared)
          headers = { "Accept" => "application/json", "Authorization" => "Bearer #{@api_key}" }
          headers["Content-Type"] = "application/json" if prepared[:body]
          url = "#{@base}#{prepared[:path]}"
          status, resp_headers, body = @transport.call(prepared[:method], url, headers, prepared[:body], @timeout, @max)
          raise ApiError.new("transport", "Redirects are refused to protect the API key.", status) if status.between?(300, 399)

          lower = resp_headers.transform_keys { |k| k.to_s.downcase }
          data = nil
          unless body.nil? || body.empty?
            raise ApiError.new("malformed_response", "SendRepute returned a non-JSON response.", status) unless lower["content-type"].to_s.match?(%r{\Aapplication/([a-z.+-]*\+)?json\b}i)

            begin
              data = JSON.parse(body, max_nesting: 128)
            rescue JSON::ParserError
              raise ApiError.new("malformed_response", "SendRepute returned invalid JSON.", status)
            end
          end
          num = ->(n) { lower[n].to_s.match?(/\A\d{1,12}\z/) ? lower[n].to_i : nil }
          { status: status, ok: status.between?(200, 299), data: data,
            rate_limit: { limit: num.call("x-ratelimit-limit"), remaining: num.call("x-ratelimit-remaining"), reset: num.call("x-ratelimit-reset"), retry_after: num.call("retry-after") } }
        end

        private

        def net_http(method, url, headers, body, timeout, max)
          uri = URI(url)
          klass = { "GET" => Net::HTTP::Get, "POST" => Net::HTTP::Post, "PUT" => Net::HTTP::Put, "PATCH" => Net::HTTP::Patch, "DELETE" => Net::HTTP::Delete }.fetch(method)
          request = klass.new(uri.request_uri)
          headers.each { |k, v| request[k] = v }
          request.body = body if body
          buffer = +""
          status = nil
          resp_headers = {}
          Timeout.timeout(timeout, ApiError.new("transport", "request exceeded deadline")) do
            Net::HTTP.start(uri.host, uri.port, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_PEER,
                                                open_timeout: [timeout, 5].min, read_timeout: timeout, write_timeout: timeout) do |http|
              http.request(request) do |response|
                status = response.code.to_i
                response.each_header { |k, v| resp_headers[k] = v }
                response.read_body do |chunk|
                  buffer << chunk
                  raise ApiError.new("response_too_large", "Response exceeds the configured limit") if buffer.bytesize > max
                end
              end
            end
          end
          [status, resp_headers, buffer]
        rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError => e
          raise ApiError.new("transport", "customer API request failed: #{e.class}")
        end
      end

      # Session-bound console policy: same-session quotes, explicit consent,
      # confirmation for billing actions, one guarded call in flight.
      class ConsoleService
        QUOTES = "sendrepute_console_quotes"
        PRICING = "sendrepute_console_pricing"
        INFLIGHT = "sendrepute_console_inflight"

        def initialize(client:, product: "Rails", handoff_return_origin: nil, enabled_operations: nil, intent_store: nil)
          raise ApiError.new("configuration", "intent_store must be an IntentLedger") unless intent_store.nil? || intent_store.is_a?(IntentLedger)

          @intents = intent_store
          if handoff_return_origin && !handoff_return_origin.match?(/\Ahttps:\/\/[a-z0-9.-]{1,253}(:\d{1,5})?\z/)
            raise ApiError.new("configuration", "handoff_return_origin must be an exact https origin.")
          end

          @client = client
          @product = product
          @origin = handoff_return_origin
          @enabled = enabled_operations
        end

        def enabled
          ids = @enabled || Catalog.operations.map { |o| o["id"] }
          @origin ? ids : ids - ["customerCreateHostedBuilderHandoff"]
        end

        def catalog(csrf)
          on = enabled
          ops = Catalog.operations.map do |op|
            entry = op.merge("enabled" => on.include?(op["id"]))
            entry["disabledReason"] = op["handoff"] && @origin.nil? ? "Configure the handoff return origin to enable hosted builder handoffs." : "Disabled by server configuration." unless entry["enabled"]
            entry
          end
          { "product" => @product, "apiVersion" => Catalog.data["apiVersion"], "csrf" => csrf, "operations" => ops }
        end

        def handle_raw(raw, session, now = Time.now.to_i)
          return [413, error("BODY_TOO_LARGE", "Console request too large")] if raw.bytesize > 655_360

          payload = JSON.parse(raw, max_nesting: 64)
          handle(payload, session, now)
        rescue JSON::ParserError, JSON::NestingError
          [400, error("INVALID_JSON", "Console request is not valid JSON")]
        end

        def handle(payload, session, now = Time.now.to_i)
          raise PolicyError.new(400, "INVALID_JSON", "Console request must name an operation") unless payload.is_a?(Hash) && payload["operationId"].is_a?(String)

          if payload["operationId"] == "sendrepute.listIntents"
            return [200, { "intents" => store.list(@client.credential_fingerprint).map { |r| public_intent(r) } }]
          end
          if payload["operationId"] == "sendrepute.releaseIntent"
            st = store
            raise PolicyError.new(428, "CONFIRMATION_REQUIRED", "Releasing an intent requires explicit confirmation") unless payload["confirm"] == true

            reason = payload["reason"]
            raise PolicyError.new(400, "INVALID_PARAMETER", "Give a reason of 3-200 characters") unless reason.is_a?(String) && reason.strip.length >= 3 && reason.length <= 200

            return [200, { "intent" => public_intent(st.release(payload["intentKey"].to_s, @client.credential_fingerprint, reason.strip, now)) }]
          end
          quotes = session[QUOTES].is_a?(Hash) ? session[QUOTES].dup : {}
          op = Catalog.get(payload["operationId"])
          prepared = Policy.prepare(payload["operationId"], { "params" => payload["params"], "query" => payload["query"], "body" => payload["body"] },
                                    enabled: enabled, paid_consent: payload["paidConsent"], confirm: payload["confirm"], require_quote: true,
                                    quoted_at: op && op["quote"] ? quotes[op["quote"]] : nil, now: now, handoff_return_origin: @origin,
                                    **(payload["operationId"] == Policy::CLASSIFY_OPERATION ? { expected_pricing: session[PRICING] } : {}))
          unless prepared[:op]["paid"] || prepared[:op]["financial"]
            upstream = @client.send_prepared(prepared)
            result = { "upstream" => upstream }
            if upstream[:ok] && Catalog.quote_operation?(prepared[:op]["id"])
              quotes[prepared[:op]["id"]] = now
              session[QUOTES] = quotes
              result["quoteRecorded"] = { "priceMillicents" => Policy.extract_quoted_price(upstream[:data]) }
              if prepared[:op]["id"] == "customerGetPricingSettings"
                # Server-returned rate schedule; classification consent must match it exactly.
                session[PRICING] = Policy.classification_rates(upstream[:data])
                result["quoteRecorded"]["pricing"] = session[PRICING]
              end
            end
            return [200, result]
          end

          st = store
          inflight = session[INFLIGHT]
          raise PolicyError.new(409, "PAID_IN_FLIGHT", "Another paid or billing operation is still running in this session") if inflight.is_a?(Integer) && now - inflight < 180

          fingerprint = @client.credential_fingerprint
          key = IntentLedger.key(fingerprint, prepared)
          field = IntentLedger.replay_field(prepared[:op])
          body = prepared[:body] ? JSON.parse(prepared[:body]) : nil
          supplied = field && body.is_a?(Hash) && body[field].is_a?(String) && !body[field].empty? ? body[field] : nil
          # Persist the intent and upstream replay identity BEFORE anything is sent.
          begun = st.begin_intent(key, { fingerprint: fingerprint, operation_id: prepared[:op]["id"], replay_field: field, replay_id: supplied || IntentLedger.new_replay_id(field) }, now)
          unless begun[:acquired]
            rec = begun[:record]
            message = case rec["state"]
                      when "completed" then "An identical paid request already completed. Release it deliberately to run a second, separate charge."
                      when "ambiguous" then "An identical paid request has an unknown outcome. Reconcile it (ledger or paid-result recovery) and release it before resending."
                      else "An identical paid request is in progress in another session or worker."
                      end
            raise IntentConflict.new(409, rec["state"] == "completed" ? "INTENT_COMPLETED" : "INTENT_LOCKED", message, rec)
          end
          if field && supplied.nil? && begun[:record]["replayId"] && body.is_a?(Hash)
            body[field] = begun[:record]["replayId"]
            prepared = prepared.merge(body: JSON.generate(body))
          end
          if prepared[:op]["paid"]
            quotes.delete(prepared[:op]["quote"])
            session[QUOTES] = quotes
            session[PRICING] = nil if prepared[:op]["id"] == Policy::CLASSIFY_OPERATION
          end
          session[INFLIGHT] = now
          begin
            upstream = @client.send_prepared(prepared)
          rescue ApiError => e
            rec = safe_finish(st, key, "ambiguous", nil, now) || begun[:record]
            raise IntentConflict.new(502, "UPSTREAM_AMBIGUOUS", "Outcome unknown (#{e.code}). Nothing was retried; the intent stays locked until reconciled.", rec)
          ensure
            session[INFLIGHT] = nil
          end
          code = upstream[:status]
          state = if upstream[:ok] then "completed"
                  elsif code.between?(400, 499) && ![408, 425].include?(code) then "failed"
                  else "ambiguous"
                  end
          rec = safe_finish(st, key, state, code, now) || begun[:record].merge("state" => "pending")
          result = { "upstream" => upstream, "intent" => public_intent(rec) }
          charged = find_int(upstream[:data], "chargedMillicents")
          consented = payload["paidConsent"].is_a?(Hash) ? (payload["paidConsent"]["maxChargeMillicents"] || payload["paidConsent"]["expectedPriceMillicents"]) : nil
          result["priceAlert"] = { "chargedMillicents" => charged, "consentedMillicents" => consented } if charged && consented.is_a?(Integer) && charged > consented
          [200, result]
        rescue IntentConflict => e
          [e.status, { "error" => { "code" => e.code, "message" => e.message, "intent" => public_intent(e.record) } }]
        rescue PolicyError => e
          [e.status, error(e.code, e.message)]
        rescue ApiError => e
          [502, error(e.code.upcase, e.message)]
        end

        def self.render_page(base_path, csrf, product)
          nonce = [SecureRandom.random_bytes(18)].pack("m0")
          esc = ->(v) { ERB::Util.html_escape(v.to_s) }
          html = File.read(File.join(RESOURCE_DIR, "admin-ui.html"))
                     .gsub("__SR_NONCE__", nonce).gsub("__SR_BASE__", esc.call(base_path)).gsub("__SR_CSRF__", esc.call(csrf))
                     .gsub("__SR_LOGIN__", "0").gsub("__SR_PRODUCT__", esc.call(product))
          csp = "default-src 'none'; script-src 'nonce-#{nonce}'; style-src 'unsafe-inline'; connect-src 'self'; img-src data:; frame-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
          [html, csp]
        end

        def self.security_headers
          { "Cache-Control" => "no-store", "X-Content-Type-Options" => "nosniff", "Referrer-Policy" => "no-referrer", "X-Frame-Options" => "DENY" }
        end

        private

        def store
          raise PolicyError.new(503, "INTENT_STORE_REQUIRED", "Paid and billing operations are disabled until a durable intent store is configured") unless @intents

          @intents
        end

        def safe_finish(st, key, state, status, now)
          st.finish(key, state, status, now)
        rescue StandardError
          nil
        end

        def public_intent(rec)
          rec&.reject { |k, _| k == "fingerprint" }
        end

        def find_int(data, name, depth = 0)
          return nil if depth > 4

          if data.is_a?(Hash)
            return data[name] if data[name].is_a?(Integer)

            data.each_value { |v| (f = find_int(v, name, depth + 1)) && (return f) }
          elsif data.is_a?(Array)
            data.each { |v| (f = find_int(v, name, depth + 1)) && (return f) }
          end
          nil
        end

        def error(code, message)
          { "error" => { "code" => code, "message" => message } }
        end
      end
    end
  end
end

require_relative "intent_store"
