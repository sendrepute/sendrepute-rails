# frozen_string_literal: true

require_relative "test_helper"
require "base64"
require "json"
require "open3"

class FixtureClient
  attr_reader :payloads

  def initialize(probability: 0.1, error: nil)
    @probability = probability
    @error = error
    @payloads = []
  end

  def classify(payload)
    raise @error if @error

    @payloads << payload
    {
      "requestId" => "req_fixture",
      "model" => "thor",
      "result" => {
        "label" => @probability >= 0.5 ? "spam" : "inbox",
        "spamProbability" => @probability,
        "confidence" => "high",
        "reasons" => [],
        "flaggedTerms" => [],
        "analyzedFields" => %w[sender subject body],
        "modelVersion" => "fixture",
        "analyzedAt" => "2025-01-01T00:00:00Z"
      },
      "billing" => { "chargedMillicents" => 1, "replayed" => false }
    }
  end
end

class ContractMailer < ActionMailer::Base
  include SendRepute::Rails::Mailer
  default from: "Example Sender <sender@example.test>"

  def opted_in
    sendrepute_paid_preflight!
    mail(to: "recipient@example.test", subject: "Fixture", body: "Visible fixture")
  end

  def not_opted_in
    mail(to: "recipient@example.test", subject: "Account alert", body: "Security fixture")
  end

  def multipart
    sendrepute_paid_preflight!
    mail(to: "recipient@example.test", subject: "Multipart") do |format|
      format.text { render plain: "benign" }
      format.html { render html: "<style>later alternative is hidden".html_safe }
    end
  end

  def ambiguous(body)
    sendrepute_paid_preflight!
    mail(to: "recipient@example.test", subject: "Ambiguous", body: body)
  end
end

class MailerTest < Minitest::Test
  def setup
    ActionMailer::Base.deliveries.clear
    SendRepute::Rails.reset_configuration!
  end

  def configure(client, mode: :advisory, failure_policy: :preserve)
    SendRepute::Rails.configure do |config|
      config.enabled = true
      config.paid_consent = true
      config.token = "server-fixture-token"
      config.mode = mode
      config.failure_policy = failure_policy
      config.client_factory = ->(_) { client }
    end
  end

  def test_real_action_mailer_delivery_calls_fixture_classifier
    client = FixtureClient.new
    configure(client)

    ContractMailer.opted_in.deliver_now

    assert_equal 1, ActionMailer::Base.deliveries.length
    assert_equal(
      { sender: "Example Sender", subject: "Fixture", body: "Visible fixture" },
      client.payloads.fetch(0)
    )
  end

  def test_no_opt_in_means_no_paid_call
    client = FixtureClient.new
    configure(client, mode: :block)

    ContractMailer.not_opted_in.deliver_now

    assert_empty client.payloads
    assert_equal 1, ActionMailer::Base.deliveries.length
  end

  def test_block_mode_aborts_confirmed_delivery_path
    configure(FixtureClient.new(probability: 0.9), mode: :block)

    ContractMailer.opted_in.deliver_now

    assert_empty ActionMailer::Base.deliveries
  end

  def test_advisory_mode_never_blocks_on_score
    configure(FixtureClient.new(probability: 1.0), mode: :advisory)

    ContractMailer.opted_in.deliver_now

    assert_equal 1, ActionMailer::Base.deliveries.length
  end

  def test_failure_policy_is_independent
    error = SendRepute::Rails::RequestError.new("offline fixture")
    configure(FixtureClient.new(error: error), mode: :advisory, failure_policy: :block)

    ContractMailer.opted_in.deliver_now

    assert_empty ActionMailer::Base.deliveries
  end

  def test_multipart_is_rejected_before_paid_call
    client = FixtureClient.new
    configure(client, failure_policy: :block)

    ContractMailer.multipart.deliver_now

    assert_empty client.payloads
    assert_empty ActionMailer::Base.deliveries
  end

  def test_configuration_rejects_invalid_threshold
    error = assert_raises(SendRepute::Rails::ConfigurationError) do
      SendRepute::Rails.configure { |config| config.score_threshold = 1.01 }
    end
    assert_match(/between 0 and 1/, error.message)
  end

  def test_real_mail_decodes_base64_single_part
    mail = Mail.read_from_string(<<~MAIL)
      From: Example Sender <sender@example.test>
      To: recipient@example.test
      Subject: Encoded
      Content-Type: text/plain; charset=UTF-8
      Content-Transfer-Encoding: base64

      VmlzaWJsZSBiYXNlNjQgYm9keQ==
    MAIL

    assert_equal "Visible base64 body", SendRepute::Rails::Message.payload(mail)[:body].strip
  end

  def test_real_mail_decodes_quoted_printable_single_part
    mail = Mail.read_from_string(<<~MAIL)
      From: Example Sender <sender@example.test>
      To: recipient@example.test
      Subject: Encoded
      Content-Type: text/plain; charset=UTF-8
      Content-Transfer-Encoding: quoted-printable

      Visible=20quoted-printable=20body
    MAIL

    assert_equal(
      "Visible quoted-printable body",
      SendRepute::Rails::Message.payload(mail)[:body].strip
    )
  end

  def test_actual_visible_email_text_hazards_are_rejected_before_paid_request
    encoded = Base64.strict_encode64("<style>spam offer malicious</style>" * 4)
    cases = {
      "css braces" => ["benign { spam offer malicious } tail", "tail"],
      "global quoted-printable" => ["benign =7B spam offer malicious =7D tail", "tail"],
      "global base64" => [encoded, ""],
      "base64 transfer header" => ["Content-Transfer-Encoding: base64\n\n#{encoded}", "Content-Transfer-Encoding: base64"]
    }

    cases.each do |name, (body, normalized)|
      assert_equal normalized, actual_visible_email_text(body), name
      client = FixtureClient.new
      configure(client, failure_policy: :block)
      ContractMailer.ambiguous(body).deliver_now
      assert_empty client.payloads, name
      assert_empty ActionMailer::Base.deliveries, name
    end
  end

  def test_raising_error_callback_cannot_override_preserve_policy
    error = SendRepute::Rails::RequestError.new("offline fixture")
    configure(FixtureClient.new(error: error), failure_policy: :preserve)
    SendRepute::Rails.configuration.on_error = ->(_) { raise "observer failed" }

    ContractMailer.opted_in.deliver_now

    assert_equal 1, ActionMailer::Base.deliveries.length
  end

  def test_error_callback_abort_cannot_override_preserve_policy
    error = SendRepute::Rails::RequestError.new("offline fixture")
    configure(FixtureClient.new(error: error), failure_policy: :preserve)
    SendRepute::Rails.configuration.on_error = ->(_) { throw(:abort) }

    ContractMailer.opted_in.deliver_now

    assert_equal 1, ActionMailer::Base.deliveries.length
  end

  def test_result_callback_cannot_access_or_mutate_live_message
    client = FixtureClient.new
    received = nil
    configure(client)
    SendRepute::Rails.configuration.on_result = lambda do |response|
      received = response
      response["model"] = "mutated"
    end

    ContractMailer.opted_in.deliver_now

    assert received.frozen?
    assert_equal "thor", received["model"]
    assert_equal 1, ActionMailer::Base.deliveries.length
  end

  def test_result_callback_abort_cannot_override_advisory_delivery
    configure(FixtureClient.new(probability: 1.0), mode: :advisory)
    SendRepute::Rails.configuration.on_result = ->(_) { throw(:abort) }

    ContractMailer.opted_in.deliver_now

    assert_equal 1, ActionMailer::Base.deliveries.length
  end

  private

  def actual_visible_email_text(body)
    cli = File.expand_path("../../../node_modules/.pnpm/tsx@4.23.1/node_modules/tsx/dist/cli.mjs", __dir__)
    script = File.expand_path("normalizer_bridge.ts", __dir__)
    stdout, stderr, status = Open3.capture3("node", cli, script, stdin_data: JSON.generate(body))
    raise "normalizer bridge failed: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end
end
