# frozen_string_literal: true

require_relative "test_helper"

class ClientTest < Minitest::Test
  class SlowClient < SendRepute::Rails::Client
    private

    def perform_request(_request)
      sleep 0.1
      [200, "{}"]
    end
  end

  def setup
    @configuration = SendRepute::Rails::Configuration.new
    @configuration.token = "fixture"
    @client = SendRepute::Rails::Client.new(@configuration)
  end

  def test_public_contract_fixture
    fixture = {
      "requestId" => "req_1",
      "model" => "thor",
      "result" => {
        "label" => "inbox",
        "spamProbability" => 0.25,
        "confidence" => "high",
        "reasons" => [],
        "flaggedTerms" => [],
        "analyzedFields" => %w[sender subject body],
        "modelVersion" => "fixture",
        "analyzedAt" => "2025-01-01T00:00:00Z"
      },
      "billing" => { "chargedMillicents" => 1, "replayed" => false }
    }
    assert_equal fixture, @client.send(:validate_response, fixture)
  end

  def test_rejects_flat_or_out_of_range_response
    assert_raises(SendRepute::Rails::ResponseError) do
      @client.send(:validate_response, { "spamProbability" => 0.1 })
    end
    assert_raises(SendRepute::Rails::ResponseError) do
      @client.send(:validate_response, {
        "requestId" => "req", "model" => "thor",
        "result" => { "spamProbability" => 2 },
        "billing" => { "chargedMillicents" => 1, "replayed" => false }
      })
    end
  end

  def test_endpoint_is_fixed_https
    assert_equal "https", SendRepute::Rails::Client::ENDPOINT.scheme
    assert_equal "www.sendrepute.com", SendRepute::Rails::Client::ENDPOINT.host
    assert_equal "/api/v1/classify", SendRepute::Rails::Client::ENDPOINT.path
  end

  def test_total_deadline_bounds_a_trickling_response
    @configuration.total_timeout = 0.01
    client = SlowClient.new(@configuration)

    error = assert_raises(SendRepute::Rails::RequestError) do
      client.classify(sender: "Sender", subject: "Subject", body: "Body")
    end
    assert_match(/total response deadline/, error.message)
  end

  def test_full_required_response_types_and_bounds
    assert_equal full_response, @client.send(:validate_response, full_response)

    invalid = full_response
    invalid["requestId"] = "r" * 129
    assert_raises(SendRepute::Rails::ResponseError) { @client.send(:validate_response, invalid) }

    invalid = full_response
    invalid["result"]["reasons"][0]["weight"] = "wrong"
    assert_raises(SendRepute::Rails::ResponseError) { @client.send(:validate_response, invalid) }

    invalid = full_response
    invalid["result"]["analyzedAt"] = "not-a-date"
    assert_raises(SendRepute::Rails::ResponseError) { @client.send(:validate_response, invalid) }

    invalid = full_response
    invalid["billing"]["chargedMillicents"] = 1.5
    assert_raises(SendRepute::Rails::ResponseError) { @client.send(:validate_response, invalid) }
  end

  private

  def full_response
    {
      "requestId" => "req_full",
      "model" => "thor",
      "result" => {
        "label" => "inbox", "spamProbability" => 0.1, "flaggedTermCount" => 0,
        "confidence" => "high",
        "reasons" => [{ "signal" => "fixture", "detail" => "detail", "weight" => 0.1 }],
        "flaggedTerms" => [], "analyzedFields" => %w[sender subject body],
        "modelVersion" => "fixture", "analyzedAt" => "2025-01-01T00:00:00Z",
        "contentAudit" => {
          "score" => 100, "grade" => "A", "summary" => "looks_good",
          "counts" => { "words" => 1, "links" => 0, "images" => 0, "triggerPhrases" => 0 },
          "totalIssues" => 0, "criticalCount" => 0, "warningCount" => 0,
          "suggestionCount" => 0, "issues" => [],
          "goodPractices" => [{ "code" => "fixture", "category" => "content" }],
          "homoglyphTerms" => [], "inputTruncated" => false
        }
      },
      "billing" => { "chargedMillicents" => 1, "replayed" => false }
    }
  end
end
