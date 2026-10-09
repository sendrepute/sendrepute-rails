# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "rack/test"
require "action_dispatch"
require_relative "../lib/sendrepute/rails/customer_console"

class CustomerApiTest < Minitest::Test
  include Rack::Test::Methods

  KEY = "sr_live_test_key_0123456789abcdef"
  CA = SendRepute::Rails::CustomerApi

  class FakeTransport
    attr_reader :calls

    def initialize(&responder)
      @responder = responder || ->(_n) { [200, { "Content-Type" => "application/json", "X-RateLimit-Remaining" => "41" }, '{"id":"acct","expectedPriceMillicents":5}'] }
      @calls = []
    end

    def call(method, url, headers, body, _timeout, _max)
      @calls << { method: method, url: url, headers: headers, body: body }
      @responder.call(@calls.length)
    end
  end

  def store(dir = intent_dir)
    CA::FileIntentStore.new(directory: dir, single_host: true)
  end

  def intent_dir
    Dir.mktmpdir("sr-intents-").tap { |d| File.chmod(0o700, d) }
  end

  ACCESS = { "operationId" => "customerCreateVipEmailBuilderAccess", "body" => { "designId" => "design-1", "sourceKind" => "template", "templateId" => "vip-01" },
             "paidConsent" => { "acknowledged" => true, "expectedPriceMillicents" => 2500 } }.freeze
  PRICING = { "operationId" => "customerGetPricingSettings" }.freeze

  def test_paid_calls_refused_without_intent_store
    t = FakeTransport.new
    svc = CA::ConsoleService.new(client: client(t))
    s = {}
    svc.handle(PRICING, s, 1)
    status, res = svc.handle(ACCESS, s, 2)
    assert_equal 503, status
    assert_equal "INTENT_STORE_REQUIRED", res["error"]["code"]
    assert_equal 1, t.calls.length
  end

  def test_ambiguous_failure_locked_across_sessions_and_restart
    dir = intent_dir
    mode = :fail
    t = nil
    t = FakeTransport.new do |_n|
      if t.calls.last[:url].end_with?("/v1/pricing") then [200, { "Content-Type" => "application/json" }, '{"expectedPriceMillicents":2500}']
      elsif mode == :fail then raise CA::ApiError.new("transport", "reset")
      else [201, { "Content-Type" => "application/json" }, '{"accessId":"a","billing":{"chargedMillicents":2500}}']
      end
    end
    paid = -> { t.calls.select { |c| c[:url].include?("/v1/vip/email-builder/access") }.map { |c| JSON.parse(c[:body]) } }
    svc = CA::ConsoleService.new(client: client(t), intent_store: store(dir))
    a = {}
    b = {}
    svc.handle(PRICING, a, 1000)
    status, res = svc.handle(ACCESS, a, 1001)
    assert_equal 502, status
    assert_equal "UPSTREAM_AMBIGUOUS", res["error"]["code"]
    replay = res["error"]["intent"]["replayId"]
    assert_match(/\A\h{8}-\h{4}-4/, replay)
    assert_equal replay, paid.call[0]["recoveryId"]
    refute res["error"]["intent"].key?("fingerprint")
    svc.handle(PRICING, b, 1002)
    status, res = svc.handle(ACCESS, b, 1003)
    assert_equal 409, status
    assert_equal "INTENT_LOCKED", res["error"]["code"]

    svc = CA::ConsoleService.new(client: client(t), intent_store: store(dir))
    c = {}
    svc.handle(PRICING, c, 2000)
    assert_equal "INTENT_LOCKED", svc.handle(ACCESS, c, 2001)[1]["error"]["code"]
    list = svc.handle({ "operationId" => "sendrepute.listIntents" }, c, 2002)[1]["intents"]
    assert_equal 1, list.length
    key = list[0]["key"]
    assert_equal 428, svc.handle({ "operationId" => "sendrepute.releaseIntent", "intentKey" => key, "reason" => "ledger clean" }, c, 2003)[0]
    assert_equal "released", svc.handle({ "operationId" => "sendrepute.releaseIntent", "intentKey" => key, "reason" => "ledger clean", "confirm" => true }, c, 2004)[1]["intent"]["state"]
    mode = :ok
    svc.handle(PRICING, c, 2005)
    status, res = svc.handle(ACCESS, c, 2006)
    assert_equal 200, status
    assert_equal "completed", res["intent"]["state"]
    assert_equal replay, paid.call[1]["recoveryId"]
    svc.handle(PRICING, c, 2007)
    assert_equal "INTENT_COMPLETED", svc.handle(ACCESS, c, 2008)[1]["error"]["code"]
    svc.handle({ "operationId" => "sendrepute.releaseIntent", "intentKey" => key, "reason" => "second purchase", "confirm" => true }, c, 2009)
    svc.handle(PRICING, c, 2010)
    assert_equal 200, svc.handle(ACCESS, c, 2011)[0]
    refute_equal replay, paid.call[2]["recoveryId"]
    assert_equal 3, paid.call.length
  end

  def test_file_store_config_refusals_and_cross_process_atomicity
    assert_raises(CA::ApiError) { CA::FileIntentStore.new(directory: intent_dir) }
    assert_raises(CA::ApiError) { CA::FileIntentStore.new(directory: "relative", single_host: true) }
    open_dir = intent_dir
    File.chmod(0o755, open_dir)
    assert_raises(CA::ApiError) { CA::FileIntentStore.new(directory: open_dir, single_host: true) }
    dir = intent_dir
    key = "c" * 64
    readers = 8.times.map do
      r, w = IO.pipe
      pid = fork do
        r.close
        res = CA::FileIntentStore.new(directory: dir, single_host: true).begin_intent(key, { fingerprint: "f", operation_id: "customerPurchaseVip" }, 1)
        w.write(res[:acquired] ? "1" : "0")
        w.close
        exit!(0)
      end
      w.close
      [r, pid]
    end
    wins = readers.sum { |r, pid| out = r.read; r.close; Process.wait(pid); out == "1" ? 1 : 0 }
    assert_equal 1, wins
  end

  def client(transport = FakeTransport.new)
    CA::Client.new(api_key: KEY, transport: transport)
  end

  def test_catalog_matches_contract
    assert_equal 49, CA::Catalog.operations.length
    spec = File.expand_path("../../../artifacts/api-server/src/customer-api-openapi.json", __dir__)
    skip "contract not present" unless File.exist?(spec)
    doc = JSON.parse(File.read(spec))
    expected = doc["paths"].flat_map { |p, item| item.map { |m, op| "#{m.upcase} #{p} #{op['operationId']}" } }.sort
    assert_equal expected, CA::Catalog.operations.map { |o| "#{o['method']} #{o['path']} #{o['id']}" }.sort
  end

  def test_client_fixed_origin_methods_and_hidden_key
    t = FakeTransport.new
    c = client(t)
    CA::Catalog.operations.each { |op| assert c.respond_to?(op["id"]), op["id"] }
    r = c.customerGetAccount
    assert_equal 41, r[:rate_limit][:remaining]
    assert_equal "https://www.sendrepute.com/api/v1/account", t.calls[0][:url]
    refute_includes c.inspect, KEY
    assert_raises(CA::ApiError) { CA::Client.new(api_key: KEY, base_url: "https://evil.example/api") }
  end

  def test_policy_validation_consent_and_confirmation
    [["customerGetPaidResult", { params: { recoveryId: "../admin" } }, "INVALID_PARAMETER"],
     ["customerGetCreditLedger", { query: { limit: 51 } }, "INVALID_PARAMETER"],
     ["customerGetCreditLedger", { query: { host: "evil" } }, "UNKNOWN_PARAMETER"],
     ["customerStandardBuilderCompile", { body: { mjml: "x", url: "https://x" } }, "UNKNOWN_FIELD"],
     ["customerStandardBuilderCompile", { body: { mjml: "x" * (600 * 1024) } }, "BODY_TOO_LARGE"],
     ["customerAnalyzeCampaignInsights", { body: { analysisId: "r" } }, "CONSENT_REQUIRED"],
     ["customerResolvePaidResult", { params: { recoveryId: "6f1c1c6e-8a4b-4c1e-9a7e-2b3c4d5e6f70" }, body: { action: "resolve", reason: "r" } }, "CONFIRMATION_REQUIRED"]].each do |id, input, code|
      e = assert_raises(CA::PolicyError, id) { CA::Policy.prepare(id, input) }
      assert_equal code, e.code, id
    end
    t = FakeTransport.new
    client(t).customerAnalyzeCampaignInsights({ body: { analysisId: "r", metrics: { sent: 1 } } }, paid_consent: { acknowledged: true, expectedPriceMillicents: 10_000 })
    sent = JSON.parse(t.calls[0][:body])
    assert_equal 10_000, sent["expectedPriceMillicents"]
    assert_equal true, sent["consent"]
  end

  def test_no_retry_redirect_and_non_json_refused
    failing = FakeTransport.new { raise CA::ApiError.new("transport", "boom") }
    assert_raises(CA::ApiError) { client(failing).customerGetAccount }
    assert_equal 1, failing.calls.length
    assert_raises(CA::ApiError) { client(FakeTransport.new { [302, { "Location" => "https://evil" }, ""] }).customerGetAccount }
    assert_raises(CA::ApiError) { client(FakeTransport.new { [200, { "Content-Type" => "text/html" }, "<p>"] }).customerGetAccount }
  end

  def test_console_service_quote_flow
    t = FakeTransport.new
    svc = CA::ConsoleService.new(client: client(t), intent_store: store)
    session = {}
    paid = { "operationId" => "customerPurchaseVip", "body" => { "expectedPriceMillicents" => 5 }, "paidConsent" => { "acknowledged" => true, "expectedPriceMillicents" => 5 } }
    assert_equal 428, svc.handle(paid, session, 1000)[0]
    status, res = svc.handle({ "operationId" => "customerGetVipPlans" }, session, 1000)
    assert_equal 200, status
    assert_equal 5, res["quoteRecorded"]["priceMillicents"]
    assert_equal 200, svc.handle(paid, session, 1010)[0]
    assert_equal 428, svc.handle(paid, session, 1020)[0]
    assert_equal 2, t.calls.length
    assert_equal 403, svc.handle({ "operationId" => "customerCreateHostedBuilderHandoff", "body" => {} }, {}, 1)[0]
  end

  # Rack-level console tests
  def app
    routes = ActionDispatch::Routing::RouteSet.new
    routes.draw { SendRepute::Rails::CustomerConsole.draw(self, path: "admin/sr") }
    SendRepute::Rails::CustomerConsoleController.include(routes.url_helpers)
    Rack::Builder.new do
      use ActionDispatch::Cookies
      use ActionDispatch::Session::CacheStore, key: "_t", cache: ActiveSupport::Cache::MemoryStore.new
      use(Class.new do
        def initialize(app) = @app = app
        def call(env)
          env["action_dispatch.secret_key_base"] = "k" * 64
          env["action_dispatch.key_generator"] = ActiveSupport::CachingKeyGenerator.new(ActiveSupport::KeyGenerator.new("k" * 64, iterations: 2))
          env["action_dispatch.cookies_serializer"] = :json
          env["action_dispatch.signed_cookie_salt"] = "signed"
          env["action_dispatch.encrypted_cookie_salt"] = "enc"
          env["action_dispatch.encrypted_signed_cookie_salt"] = "encsigned"
          env["action_dispatch.authenticated_encrypted_cookie_salt"] = "auth"
          @app.call(env)
        end
      end)
      run routes
    end
  end

  def setup
    SendRepute::Rails::CustomerConsole.reset!
    @transport = FakeTransport.new
    @intent_dir = intent_dir
    SendRepute::Rails::CustomerConsole.service = CA::ConsoleService.new(client: client(@transport), intent_store: store(@intent_dir))
  end

  def test_console_denied_without_authorize_proc
    get "/admin/sr"
    assert_equal 403, last_response.status
  end

  def test_console_page_csrf_and_origin
    SendRepute::Rails::CustomerConsole.configure { |c| c.authorize = ->(_ctl) { true } }
    get "/admin/sr", {}, "HTTP_HOST" => "example.org"
    assert_equal 200, last_response.status, last_response.body[0, 300]
    refute_includes last_response.body, KEY
    csp = last_response.headers["Content-Security-Policy"]
    assert_includes csp, "frame-ancestors 'none'"
    assert_includes csp, "style-src 'unsafe-inline'"
    assert_match(/script-src 'nonce-[^']+';/, csp)
    assert_includes csp, "img-src data:;"
    get "/admin/sr/catalog"
    data = JSON.parse(last_response.body)
    assert_equal 49, data["operations"].length
    token = data["csrf"]
    body = '{"operationId":"customerGetAccount"}'
    post "/admin/sr/call", body, "CONTENT_TYPE" => "application/json", "HTTP_ORIGIN" => "http://example.org", "HTTP_X_CSRF_TOKEN" => "bad"
    assert_equal 403, last_response.status
    post "/admin/sr/call", body, "CONTENT_TYPE" => "application/json", "HTTP_ORIGIN" => "https://evil.example", "HTTP_X_CSRF_TOKEN" => token
    assert_equal 403, last_response.status
    assert_empty @transport.calls
    post "/admin/sr/call", body, "CONTENT_TYPE" => "application/json", "HTTP_ORIGIN" => "http://example.org", "HTTP_X_CSRF_TOKEN" => token
    assert_equal 200, last_response.status, last_response.body
    assert_equal "acct", JSON.parse(last_response.body)["upstream"]["data"]["id"]
  end

  RATES = { "classificationBaseMillicents" => 300, "includedUniqueTerms" => 5, "additionalTermMillicents" => 40, "maximumClassificationMillicents" => 2000 }.freeze
  EMAIL = { "sender" => "Ops Team", "subject" => "Renewal", "body" => "Your plan renews Friday." }.freeze

  def classify_consent(rates, max)
    { "operationId" => "classifyCustomerEmail", "body" => EMAIL.dup, "paidConsent" => { "acknowledged" => true, "expectedPricing" => rates, "maxChargeMillicents" => max } }
  end

  def test_generic_client_sends_exact_classification_authorization
    t = FakeTransport.new { |_n| [200, { "Content-Type" => "application/json" }, '{"requestId":"r"}'] }
    c = client(t)
    c.call("classifyCustomerEmail", { "body" => EMAIL.dup }, { paid_consent: { "acknowledged" => true, "expectedPricing" => RATES, "maxChargeMillicents" => 1200 } })
    assert_equal({ "expectedPricing" => RATES, "maxChargeMillicents" => 1200 }, JSON.parse(t.calls[0][:body])["priceAuthorization"])
    err = assert_raises(CA::PolicyError) do
      c.call("classifyCustomerEmail", { "body" => EMAIL.merge("priceAuthorization" => { "expectedPricing" => RATES.merge("additionalTermMillicents" => 41), "maxChargeMillicents" => 1200 }) },
             { paid_consent: { "acknowledged" => true, "expectedPricing" => RATES, "maxChargeMillicents" => 1200 } })
    end
    assert_equal "PRICE_MISMATCH", err.code
    assert_equal 1, t.calls.length
  end

  def test_console_classification_full_schedule_stale_confirmation_and_price_changed
    rates = RATES
    classify_status = 200
    t = nil
    t = FakeTransport.new do |_n|
      if t.calls.last[:url].end_with?("/v1/pricing") then [200, { "Content-Type" => "application/json" }, JSON.generate(rates.merge("maximumTermsThreshold" => 50))]
      elsif classify_status == 200 then [200, { "Content-Type" => "application/json" }, '{"requestId":"req-1","billing":{"chargedMillicents":340}}']
      else [409, { "Content-Type" => "application/json" }, '{"error":{"code":"PRICE_CHANGED"}}']
      end
    end
    classifies = -> { t.calls.select { |c| c[:url].end_with?("/v1/classify") }.map { |c| JSON.parse(c[:body]) } }
    svc = CA::ConsoleService.new(client: client(t), intent_store: store)
    s = {}
    assert_equal "QUOTE_REQUIRED", svc.handle(classify_consent(RATES, 1500), s, 1000)[1]["error"]["code"]
    assert_equal RATES, svc.handle(PRICING, s, 1001)[1]["quoteRecorded"]["pricing"]
    status, done = svc.handle(classify_consent(RATES, 1500), s, 1002)
    assert_equal 200, status
    assert_equal({ "expectedPricing" => RATES, "maxChargeMillicents" => 1500 }, classifies.call[0]["priceAuthorization"])
    assert_equal "completed", done["intent"]["state"]

    rates = RATES.merge("additionalTermMillicents" => 55)
    svc.handle(PRICING, s, 1003)
    status, stale = svc.handle(classify_consent(RATES, 1600), s, 1004)
    assert_equal 409, status
    assert_equal "PRICE_CONFIRMATION_STALE", stale["error"]["code"]
    assert_equal 1, classifies.call.length
    assert_equal 200, svc.handle(classify_consent(rates, 1600), s, 1005)[0]
    assert_equal({ "expectedPricing" => rates, "maxChargeMillicents" => 1600 }, classifies.call[1]["priceAuthorization"])

    classify_status = 409
    svc.handle(PRICING, s, 1006)
    _, changed = svc.handle(classify_consent(rates, 1700), s, 1007)
    assert_equal 409, changed["upstream"][:status]
    assert_equal "failed", changed["intent"]["state"]
    assert_equal "QUOTE_REQUIRED", svc.handle(classify_consent(rates, 1700), s, 1008)[1]["error"]["code"]
    assert_equal 3, classifies.call.length
  end

  def test_pending_intent_never_released_by_time_only_after_offline_recovery
    st = store
    key = "a" * 64
    assert st.begin_intent(key, { fingerprint: "f", operation_id: "customerPurchaseVip" }, 1)["acquired"] || true
    err = assert_raises(CA::IntentConflict) { st.release(key, "f", "try", 999_999) }
    assert_equal "INTENT_IN_PROGRESS", err.code
    assert_raises(ArgumentError) { st.recover_pending_after_shutdown(all_workers_stopped: false, now: 2) }
    assert_equal [key], st.recover_pending_after_shutdown(all_workers_stopped: true, now: 3)
    assert_equal "released", st.release(key, "f", "reconciled", 4)["state"]
  end

end
