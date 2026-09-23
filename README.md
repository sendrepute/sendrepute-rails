> **Standalone source distribution:** this repository contains the integration runtime, documentation, and source packager. Upstream workspace/CMS/production-normalizer regression suites are deliberately not distributed here because they depend on private server code or isolated platform fixtures. Testing commands and historical verification evidence below describe upstream maintainer validation, not a self-contained test suite in this source-only checkout. No third-party registry publication is implied.

# SendRepute Rails adapter

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
