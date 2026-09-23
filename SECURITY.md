# Security

Report vulnerabilities privately to the security contact listed at
https://www.sendrepute.com. Do not include API tokens or real message content.

The token belongs only in server-side Rails credentials or environment-backed
configuration. Never put it in mail headers, templates, browser code, logs, or
job arguments. Rotate a token after suspected disclosure.

The adapter has no retry or redirect behavior. It limits decoded request body
content to 524,288 bytes, limits responses to 1 MiB, verifies TLS, applies
separate connect/read/write deadlines, and enforces a total request/response
deadline. All deadlines are capped at 30 seconds. Multipart and non-text messages are
rejected before the paid request because separately normalized MIME fragments
can hide or consume later alternatives. CSS braces, quoted-printable-like
sequences, embedded base64 transfer headers, and whole-body base64 candidates
are also rejected before payment because the service normalizer can transform
or remove their content.

Keep `enabled` and `paid_consent` false until an administrator has reviewed
pricing and data handling. Keep account recovery, login, MFA, billing, and
other critical messages unclassified unless a user explicitly opts that exact
mailer action in. `failure_policy = :preserve` avoids turning an advisory
service outage into lost mail; select `:block` only after operational review.
