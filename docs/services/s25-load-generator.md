# S25: Load generator (Go CLI)

**Layer:** local (`loadgen/`) · **Session:** built incrementally (4 → 7) · **Concept:** (none)

## Purpose
Your own traffic + chaos tool. Built incrementally: a minimal signed-request version alongside S13/S14 (its Verify items need it), the full `--chaos`/histogram version before S27.

## Requirements that carry hidden depth
- **Correct HMAC signing, secret from SSM (25.2):** reads the webhook secret via your SSO profile (or `--secret-file`) and signs exactly as ingest verifies. If your loadgen and ingest disagree on the signing scheme, *everything* returns 401, a good forcing function for getting the contract right.
- **Realistic event mix (25.2):** random customer pool (default 50), amounts **log-normal in cents**, eventType weighted 80/15/5 settled/pending/failed. Realistic distributions make the fraud velocity rules and the reconciler actually exercise.
- **`--chaos` injects real failure classes (25.3):** 10% per-request: bad signature, malformed JSON, duplicate `providerEventId` (from the last 100), valid-but-unknown eventType. This is what feeds the DLQ/redrive and idempotency paths in the game days.
- **Worker-pool goroutines + `time.Ticker` rate limiter (25.5):** deliberately **your goroutines/channels exercise**; no `vegeta` import for the core loop (wrap it later to compare). This is the Go-concurrency learning, not just a means to an end.
- **Live p50/p95/p99 + status histogram; exit non-zero on any 5xx (25.4):** makes it usable as a CI/gate and a measurement tool.

## What the Verify is really testing
No standalone Verify; it's the **instrument** other Verifies depend on: S14.6 (p99 measurement), S21.13 (the 500-message flood + kill-task load), R9.2 (find the ingest ceiling). If those measurements are trustworthy, the loadgen works.

## Cross-links
- Used by → `services/s14-api-gateway.md`, `services/s21-ecs.md`, `sessions/session-07.md` (R9.2).
- The ceiling it probes → `decisions/ingest-concurrency.md`.

## Done when
Minimal signed version exists for S14/S13 Verifies; the full `--chaos` + histogram + goroutine-pool version exists before S27.
