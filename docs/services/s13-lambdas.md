# S13: Lambda functions

**Layer:** 10-serverless · **Session:** 4 (ingest, archiver) / 6 (notify, canary, reconciler) · **Concept:** `concepts/least-privilege.md`, `concepts/observability-slo.md` · **Decision:** `decisions/ingest-concurrency.md`

## Purpose
The five serverless functions. Ingest + archiver land in Session 4 (first flow); notify + canary + reconciler in Session 6 (complete the fan-out + observability).

## Shared contract: the parts that bite
- **`provided.al2023`, arm64, single `bootstrap` binary (13.1):** Go custom runtime, `CGO_ENABLED=0 GOOS=linux GOARCH=arm64`.
- **No VPC config (13.6):** all five run **outside** the VPC because they touch only AWS APIs → free egress + fast cold starts. Contrast the ECS services, which *are* in the VPC and need endpoints. Putting a Lambda in the VPC "to be safe" would cost you cold-start time and an ENI for nothing.
- **Terraform-managed 14-day log groups (13.2):** never rely on auto-created infinite-retention groups (cost creep).
- **Active tracing + structured slog (13.3/13.4):** `traceId`/`providerEventId` in every line.
- **Secrets fetched from SSM at cold start and cached (13.5):** not baked into env.

## Per-function depth
- **ingest (13.7, 13.13):** constant-time HMAC compare (`hmac.Equal`) over the **raw** body; bad sig → **401**, bad JSON/schema → **422**, success → **202** `{"eventId":...}`. **Does not touch DynamoDB.** **Reserved concurrency capped** (~50), your `decisions/ingest-concurrency.md` ADR (reserved = a cap, ≠ provisioned = pre-warmed).
- **archiver (13.8/13.9):** SQS ESM batch 25 / window 30s / **`ReportBatchItemFailures`**; a 10-batch with 1 failure returns *exactly* that messageId (unit-test it). Aggregates the batch into **one** NDJSON object per invocation.
- **notify (13.8):** SQS ESM batch 10, partial-batch failure; drops `synthetic=true` before side-effects. Its queue backs up from Session 4 until this deploys.
- **canary (13.10):** signed synthetic event (`synthetic=true`); GETs `/healthz` and **tolerates its absence** (layer 30 may be down; log and skip, *not* a failure). Emits `CanaryIngestOk`/`CanaryIngestLatencyMs` (the availability SLI).
- **reconciler (13.11):** counts archive vs GSI2 for yesterday; emits `ReconciliationDrift`; **WARN only above a documented threshold** (velocity scoring is racy; small drift is expected, not a bug).
- **Roles: each function gets exactly its calls (13, per-function column):** e.g. ingest = `ssm:GetParameter` on the one secret + `sns:Publish` on the one topic + logs + xray. This is the `least-privilege` "scope from access patterns" method, pre-listed for you.

## What the Verify is really testing
Ingest's **401/422/202** proves signature verification and the does-not-touch-DynamoDB boundary. Archiver's **partial-batch failure** proves one bad message in a batch of 10 doesn't force all 10 to redeliver. Both are correctness behaviors, not smoke tests.

## Cross-links
- Per-function least privilege → `concepts/least-privilege.md`.
- Reserved vs provisioned concurrency → `decisions/ingest-concurrency.md`.
- EMF metrics, canary, reconciler drift → `concepts/observability-slo.md`.

## Done when
Ingest + archiver flow end-to-end (Session 4); notify/canary/reconciler complete the system (Session 6); every role is exact; partial-batch and status-code behaviors are unit-tested.
