# Codex sign-in through the per-run cluster proxy

A ChatGPT sign-in access token cannot call `https://api.openai.com/v1/responses`:
the platform API answers `401` with `Missing scopes: api.responses.write`.
A local stub upstream can show the CLI's custom-provider behaviour, but
not whether a real upstream accepts the credential.

A host probe with Codex 0.158.0, model `gpt-6-sol`, an isolated `CODEX_HOME`
with no `auth.json`, and a custom Responses provider succeeded against
`https://chatgpt.com/backend-api/codex`. It supplied the host auth file's
`tokens.access_token` as bearer and `tokens.account_id` as
`ChatGPT-Account-Id`, with `requires_openai_auth=false` and
`supports_websockets=false`. The reply was `pong` and Codex emitted a normal
`turn.completed` event. This proves that route and credential pair for the
probed CLI version and account.

The pod uses the same provider with a placeholder bearer. The per-run proxy
replaces both Authorization and ChatGPT-Account-Id from its private key volume,
and forwards only `/responses` and `/responses/compact` to the ChatGPT backend.
The host keeper refreshes auth and installs both values together; neither
value enters the agent pod. The refresh token stays in the host auth file.
