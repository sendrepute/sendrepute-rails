# frozen_string_literal: true

require "action_controller"
require "erb"
require "securerandom"
require_relative "customer_api"

module SendRepute
  module Rails
    # Opt-in operator console. Require "sendrepute/rails/customer_console",
    # configure, then mount inside config/routes.rb:
    #
    #   SendRepute::Rails::CustomerConsole.configure do |c|
    #     c.api_key = Rails.application.credentials.sendrepute_customer_api_key
    #     c.authorize = ->(controller) { controller.current_user&.admin? }
    #   end
    #   SendRepute::Rails::CustomerConsole.draw(self, path: "admin/sendrepute")
    #
    # Without an authorize proc every request is refused (deny by default).
    # Paid and billing operations are also refused until a durable intent store
    # is configured, for example (single host only):
    #
    #     c.intent_store = SendRepute::Rails::CustomerApi::FileIntentStore.new(
    #       directory: Rails.root.join("storage/sendrepute-intents").to_s, single_host: true)
    #
    # Multi-host deployments must supply their own IntentLedger subclass backed
    # by shared storage with atomic locking.
    module CustomerConsole
      class Settings
        attr_accessor :api_key, :authorize, :handoff_return_origin, :enabled_operations, :timeout, :max_response_bytes, :parent_controller, :intent_store

        def initialize
          @timeout = 20
          @max_response_bytes = 8_388_608
          @parent_controller = "ActionController::Base"
        end
      end

      class << self
        def settings
          @settings ||= Settings.new
        end

        def configure
          yield settings
        end

        def reset!
          @settings = Settings.new
          @service = nil
        end

        attr_writer :service

        def service
          @service ||= CustomerApi::ConsoleService.new(
            client: CustomerApi::Client.new(api_key: settings.api_key, timeout: settings.timeout, max_response_bytes: settings.max_response_bytes),
            product: "Rails", handoff_return_origin: settings.handoff_return_origin, enabled_operations: settings.enabled_operations,
            intent_store: settings.intent_store
          )
        end

        def draw(routes, path: "sendrepute/customer-api")
          raise ArgumentError, "invalid console path" unless path.match?(%r{\A[A-Za-z0-9/_-]{1,80}\z})

          routes.scope(path: path, as: "sendrepute_customer_api") do
            routes.get "/", to: "send_repute/rails/customer_console#index", as: :console
            routes.get "/catalog", to: "send_repute/rails/customer_console#catalog", as: :catalog
            routes.post "/call", to: "send_repute/rails/customer_console#call", as: :call
          end
        end
      end
    end

    class CustomerConsoleController < ActionController::Base
      self.allow_forgery_protection = true
      protect_from_forgery with: :exception
      before_action :authorize_operator!
      before_action :require_same_origin!, only: :call

      def index
        html, csp = CustomerApi::ConsoleService.render_page(request.path.chomp("/"), form_authenticity_token, "Rails")
        apply_headers
        response.headers["Content-Security-Policy"] = csp
        render html: html.html_safe, content_type: "text/html"
      end

      def catalog
        apply_headers
        render json: CustomerConsole.service.catalog(form_authenticity_token)
      end

      def call
        apply_headers
        unless request.media_type == "application/json"
          return render(json: { error: { code: "JSON_REQUIRED", message: "JSON body required" } }, status: 415)
        end

        status, payload = CustomerConsole.service.handle_raw(request.raw_post.to_s, session)
        render json: payload, status: status
      end

      private

      def authorize_operator!
        check = CustomerConsole.settings.authorize
        return if check.respond_to?(:call) && check.call(self) == true

        apply_headers
        render json: { error: { code: "FORBIDDEN", message: "Operator authorization required" } }, status: :forbidden
      end

      def require_same_origin!
        origin = request.headers["Origin"].to_s
        host = begin
          URI(origin).host
        rescue URI::InvalidURIError
          nil
        end
        return if !origin.empty? && host == request.host

        apply_headers
        render json: { error: { code: "ORIGIN_REFUSED", message: "Cross-origin console request refused" } }, status: :forbidden
      end

      def handle_unverified_request
        raise ActionController::InvalidAuthenticityToken
      end

      rescue_from ActionController::InvalidAuthenticityToken do
        apply_headers
        render json: { error: { code: "CSRF_REFUSED", message: "CSRF validation failed" } }, status: :forbidden
      end

      def apply_headers
        CustomerApi::ConsoleService.security_headers.each { |k, v| response.headers[k] = v }
      end
    end
  end
end
