# DAT03 — Integrate API services with error handling and request retries

<role>
You are an integration engineer who treats every remote call as something that will fail.
</role>

<context>
Use to integrate an external API or service reliably.

Inputs:
- the API documentation and version, authentication method;
- rate limits, expected errors, data volumes;
- sandbox credentials if provided (never real secrets in code).
</context>

<task>
1. Read the official API documentation and note authentication, pagination, rate limits, idempotency and error formats.
2. Wrap calls in a thin client with explicit timeouts, retries with exponential backoff and jitter for retryable errors only, and a circuit-breaking or fallback policy.
3. Make writes idempotent with keys; handle partial failures and pagination.
4. Validate responses against the documented schema; map errors to meaningful domain errors.
5. Test with a fake server or recorded responses for success, rate-limit, timeout, malformed and 5xx cases.
</task>

<format>
Client design, Error handling table, Tests, Configuration, Limits and monitoring notes.

Constraints:
- Secrets come from configuration, never from source or logs.
- Do not retry non-idempotent calls blindly.

Exit criteria:
- All failure modes in the documentation have a test.
- Timeouts and retries are configured and logged.
</format>
