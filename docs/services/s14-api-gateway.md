# S14: API Gateway

**Layer:** 10-serverless · **Session:** 4 · **Concept:** `concepts/cost-and-teardown.md` · **Decision:** `decisions/ingest-concurrency.md`

## Purpose
The public front door for webhooks: the one internet-facing entry point of the always-on path.

## Requirements that carry hidden depth
- **HTTP API, not REST (14.1):** cheaper and sufficient for a Lambda-proxy webhook. Choosing REST here would pay for features (usage plans, request validation) you don't need. Payload format **2.0**.
- **Throttle 25 rps / burst 50 (14.3):** the **wallet guard**. It pairs with ingest's reserved concurrency (S13.13) as **two independent ceilings** at two layers: a runaway loadgen loop can't fan out into a bill. The R9.2 game day asks which ceiling bites first at burst (see `decisions/ingest-concurrency.md`).
- **Custom domain needs cert A (14.5):** `webhook.aws.gmora.work`, regional, cert from S18. This is the **sequencing subtlety**: cert A must exist in an always-on layer *now* (see `decisions/cert-placement.md`), earlier than S18's nominal session, or defer the custom domain and use the raw `execute-api` endpoint until then.
- **Access logs to `/lf/apigw/ingest` (14.4):** 14-day retention, JSON with `requestId`/`status`/`integrationErrorMessage`/`responseLatency`. Your first line of "what did the front door see."

## What the Verify is really testing
**14.6, unsigned POST → 401; signed valid → 202 in < 500 ms p99** (measure with loadgen, 10 rps × 2 min). It proves the end-to-end front-door path *and* its latency SLO (`observability-slo`). **Predict-before-test:** predict the p99 and the unsigned status (401) before measuring.

## Cross-links
- The two-ceiling wallet protection → `decisions/ingest-concurrency.md`.
- Cert-A sequencing → `decisions/cert-placement.md`, `sessions/session-04.md`.
- The ingest handler behind it → `services/s13-lambdas.md`.

## Done when
HTTP API routes `POST /webhook` to ingest with throttling and access logs; unsigned → 401, signed → 202 < 500 ms p99 (predicted first); custom domain attached (or deferred by decision).
