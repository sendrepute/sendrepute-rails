# SendRepute Rails adapter

## Control panel preview

![SendRepute Rails console](https://raw.githubusercontent.com/sendrepute/sendrepute-rails/main/docs/screenshots/dashboard.webp)

The shipped controller mounted in a local ActionPack host with sample data, not a complete Rails application. See `docs/screenshots/dashboard.provenance.json` for capture details.

Version 0.1.0 is a small Action Mailer pre-delivery adapter for Rails 7.1+.
Classification is paid, advisory by default, never sends mail itself, and does
not guarantee inbox placement. This gem has not been published to RubyGems.

## Install

Use the source archive or local checkout:

```ruby
gem "sendrepute-rails", path: "vendor/sendrepute-rails"
```

Include the integration in `ApplicationMailer`:

```ruby
class ApplicationMailer < ActionMailer::Base
  include SendRepute::Rails::Mailer
end
```

Configure it on the server. Both paid gates default to false.

```ruby
SendRepute::Rails.configure do |config|
  config.enabled = true
  config.paid_consent = true # acknowledgement that each unique request may cost money
  config.token = Rails.application.credentials.dig(:sendrepute, :api_token)
  config.mode = :advisory             # or :block
  config.failure_policy = :preserve   # independent: or :block
  config.score_threshold = 0.8        # inclusive, 0..1
  config.open_timeout = 3
  config.read_timeout = 5
  config.write_timeout = 5
  config.total_timeout = 10 # bounds the complete TLS request and streamed response
end
```

Finally, opt in each non-critical mailer action explicitly:

```ruby
def newsletter
  sendrepute_paid_preflight!
  mail(to: params[:to], subject: "News")
end
```

Do not call the opt-in hook from password reset, MFA, login, verification,
billing, security alert, or other critical account routes. There is no global
auto-opt-in route.

`:advisory` records results through `on_result` but preserves delivery for any
score. `:block` aborts Action Mailer's `before_deliver` callback only when the
server returned `result.spamProbability >= score_threshold`. The separate
failure policy controls API, decoding, unsupported-message, and schema errors.
Callbacks receive only one argument: a deeply frozen `response`, or the
`error`. They never receive the live message, and callback exceptions are
contained. Callback `throw(:abort)` control flow is caught locally as well, so
an observer cannot change the selected delivery policy. Do not log bodies or
authorization data.

Only a single `text/plain` or `text/html` displayed body is accepted. Multipart
messages are rejected before payment rather than approving all alternatives
from one benign part. The original `Mail::Message`, headers, body, attachments,
and delivery transport are not modified. Mail's real transfer decoding runs on
the one accepted body. Before payment, the adapter also rejects CSS braces,
quoted-printable-like sequences, embedded base64 transfer headers, and bodies
that trigger the backend's whole-body base64 autodetection. These conservative
rejections prevent the backend normalizer from decoding or stripping accepted
content while preserving ordinary unambiguous text and HTML.

The client always posts `{sender, subject, body}` to
`https://www.sendrepute.com/api/v1/classify`. It accepts the public nested
`requestId`, `model`, `result`, and `billing` envelope and uses
`result.spamProbability`. Required response fields, nested item types, enums,
bounds, timestamps, billing integers, and optional content-audit structures are
validated. It neither follows redirects nor retries. Every configurable
network deadline is positive and capped at 30 seconds; `total_timeout` bounds
the entire connect/write/read operation, including a trickling response.

## Verification evidence

The test suite is written against actual `actionmailer` and `mail` dependencies,
Action Mailer's `:test` delivery transport, and offline classifier fixtures; it
makes no paid request and sends no email. It covers opt-in, advisory/block behavior,
independent failure policy, multipart and backend-ambiguity rejection before
classification, exact real-normalizer probes, callback isolation, a trickling
response deadline, payload extraction, endpoint pinning, threshold validation,
and typed nested response validation.
Run `bundle exec ruby -Itest test/mailer_test.rb` and
`bundle exec ruby -Itest test/client_test.rb`.

Runtime verification passed on Ruby 3.2.2 with the real Action Mailer 7.1.6
and Mail 2.9.1 dependencies: 19 runs, 59 assertions, zero failures/errors.
The CSS-brace, quoted-printable, base64-header, and whole-body base64 probes
execute the checked-in production `visibleEmailText` function itself.
The same callback suite also passed on Action Mailer 7.2.3.2. This is narrow
evidence for the tested Rails 7.1/7.2 delivery paths, not a broad certification
of untested versions. See `.local/rails-contract.md` for exact evidence.

Build the deterministic, allowlisted production source archive with
`ruby scripts/package.rb`. The archive excludes tests, caches, credentials,
vendor trees, and local configuration.

## Customer API client and operator console

`SendRepute::Rails::CustomerApi::Client.new(api_key: ...)` has a method for each of the 49 customer API operations, for example `client.customerGetAccount`, plus a generic `call(operation_id, input, options)`.

Its safeguards:

- It uses a fixed HTTPS origin through Net::HTTP.
- It never retries a request, refuses redirects and caps responses.
- Parameters and body fields must match the contract, and bodies are limited to 512 KiB.
- Paid operations require `paid_consent: { acknowledged: true, expectedPriceMillicents: N }`.
- Billing and recovery actions require `confirm: true`.

The opt-in console:

```ruby
# config/initializers/sendrepute.rb
require "sendrepute/rails/customer_console"
SendRepute::Rails::CustomerConsole.configure do |c|
  c.api_key = Rails.application.credentials.sendrepute_customer_api_key
  c.authorize = ->(controller) { controller.respond_to?(:current_user) && controller.current_user&.admin? }
end

# config/routes.rb
SendRepute::Rails::CustomerConsole.draw(self, path: "admin/sendrepute")
```

Without an `authorize` proc that returns `true`, every request is refused.

Console safeguards:

- CSRF uses Rails `protect_from_forgery` with the `X-CSRF-Token` header, plus a same-origin `Origin` check.
- A paid operation needs its quote operation to have run in the same session within the last 15 minutes. That quote is used up by the paid call.
- Only one paid or billing call can be in flight per session.
- The API key never reaches the browser.

The Action Mailer interceptor is unchanged.

## Paid-intent ledger (anti-duplicate)

Every paid or billing console call is recorded in a durable intent ledger **before** the request is sent. The identity is the credential fingerprint, operation, method, path and canonical body. An identical request is refused (409 `INTENT_LOCKED` / `INTENT_COMPLETED`) from any session, worker or restart while the intent is pending, ambiguous (timeout, transport error, 5xx, 408/425, malformed response) or completed. Definitive 4xx refusals unlock it. The upstream replay identity (`recoveryId`, or `analysisId`) is generated once, persisted with the intent and reused on resend, so the server can deduplicate. Operators review intents with the **Paid intents** button and release one only with a reason and an explicit confirmation. Releasing a completed intent issues a fresh replay id for a deliberate second charge. Pending intents are never released online or by timeout, because a stalled worker may still have the request in flight. After a worker crash, stop every worker and run `store.recover_pending_after_shutdown(all_workers_stopped: true, now: Time.now.to_i)`; leftover pending intents become ambiguous for reconciliation and release. With no ledger configured, paid and billing operations return 503 `INTENT_STORE_REQUIRED`. The filesystem store supports a **single host only**, and it refuses to start unless you acknowledge that and its directory is absolute, `0700` and owned by the server user. Prices are always sent upstream for server-side enforcement, and a charge above consent is flagged. Classification (`classifyCustomerEmail`, POST /v1/classify) sends `priceAuthorization` with the four effective rates returned by this session's latest GET /v1/pricing plus the operator's ceiling. A confirmation that no longer matches the latest rates is refused (409 `PRICE_CONFIRMATION_STALE`) before anything is sent. The server re-checks rates and ceiling atomically at settlement (409 `PRICE_CHANGED`, no debit). Manual edit reclassification (`customerClassifyEmail`, POST /v1/classify/edit) has no price field in its request schema (`CustomerManualEditInput`, additionalProperties false); the server prices it authoritatively.

```ruby
SendRepute::Rails::CustomerConsole.configure do |c|
  c.intent_store = SendRepute::Rails::CustomerApi::FileIntentStore.new(
    directory: Rails.root.join("storage/sendrepute-intents").to_s, single_host: true) # single host only
end
```

Multi-host deployments must supply their own `IntentLedger` subclass backed by shared storage with atomic locks.
