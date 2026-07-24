# S24: CloudWatch (logs, metrics, alarms, dashboard)

**Layer:** 10 (+ compute alarms in 30) · **Session:** 6 · **Concept:** `concepts/observability-slo.md`, `concepts/cost-and-teardown.md` · **Decision:** `decisions/tracing.md`

## Purpose
The observability core: where the system becomes visible, its SLOs provable, and its failures catchable. Culminates in the capstone that proves the whole thing works.

## Requirements that carry hidden depth
- **EMF only, namespace `LedgerFlow`, < 10 streams (24):** no `PutMetricData` in hot paths (cost + latency). Every metric × dimension-value is a billed stream; keep dimensions low-cardinality (`reason`, `eventType`) or absent. Adding a dimension is a cost decision (`cost-and-teardown`).
- **Two-speed burn-rate alarms (24):** ingest fast burn (> 5%/5min → page) and slow burn (> 1%/1h → ticket), via metric math over Errors/Invocations. Alert on **budget burn rate**, not raw error counts: the difference between trusted pages and alarm fatigue (`observability-slo`).
- **`treat_missing_data = breaching` on the canary alarm (24):** for a liveness signal, **silence must mean broken**, not fine. The subtlety that catches a *dead* canary.
- **SLO doc with error budget *by hand* (24.3):** 99.5%/30d availability (SLI = canary success), p99 < 500ms, event→ledger p95 < 60s. Compute the budget yourself once: 0.5% × 30d ≈ 216 min. The hand-calc *is* the requirement.
- **Dashboard L1/L2/L3 + committed Logs Insights queries (24.1/24.2):** healthy-for-users / where's-the-problem / dig-in; three saved queries committed to runbooks so debugging is reproducible under pressure.
- **Tracing (24.4, [you decide]):** ADOT sidecar vs OTel SDK on the ECS services (both OTel→X-Ray; X-Ray SDK is maintenance-mode). Lambdas active tracing. **The real work is `traceparent` propagation across SNS/SQS** (message attributes → span links). See `decisions/tracing.md`.

## What the Verify is really testing
**24.5 (the capstone):** revoke `fraud-worker`'s `dynamodb:PutItem` (one-line TF). **Predict-before-test:** which alarm fires and how fast? (Expected: `lf-fraud-backlog-age` < 10 min; writes fail → messages not deleted → oldest-age climbs past 300s.) Then the runbook `backlog-growing.md` must lead from the email → CloudTrail/IAM → the exact denial. This is the entire observability thesis in one exercise: real failure → symptom alarm → traced cause.

## Cross-links
- SLI/SLO/burn-rate/tracing depth → `concepts/observability-slo.md`.
- CloudWatch cost traps → `concepts/cost-and-teardown.md`.
- Sidecar vs SDK → `decisions/tracing.md`.

## Done when
EMF metrics under budget; burn-rate + symptom alarms fire correctly; SLO doc with hand-computed budget; L1/L2/L3 dashboard + saved queries; one end-to-end trace; the S24.5 capstone proven with a logged prediction and a working runbook.
