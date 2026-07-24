# Session 6: the remaining Lambdas, scheduling, and full observability (S13-rest, S23, S24)

**Covers:** the spec's "Session 11-13" block: the **notify / canary / reconciler** Lambdas (the rest of S13), **S23** EventBridge Scheduler, and **S24** CloudWatch (EMF metrics, burn-rate alarms, the SLO doc, the dashboard, and tracing). This is where the system stops being a pipeline and becomes **observable**: where you can *see* it working, *prove* its SLOs, and *catch* it failing. It culminates in the capstone (S24.5): revoke a permission and watch the right alarm fire and lead you to the cause.

> Read `concepts/observability-slo.md` cover to cover first: SLI/SLO/error-budget arithmetic, EMF and cardinality-as-cost, two-speed burn-rate alarms, `treat_missing_data`, the canary, and `traceparent` propagation. Have `decisions/canary-schedule.md` and `decisions/tracing.md` open. Mostly back in **layer 10** (the Lambdas/scheduler/most alarms), with some compute alarms in 30.

---

## The frame

Everything so far *ran*; almost nothing was *visible*. Session 6 closes that gap in three moves:

1. **Complete the fan-out consumers.** `notify` finally consumes `notify-q` (which has been filling since Session 4, now it drains), and `canary`/`reconciler` come online on schedules. The event system is now whole.
2. **Instrument deliberately.** EMF metrics (not `PutMetricData`), a namespace under 10 streams, structured logs, tracing across the async gap. This is where the cost discipline of observability (`cost-and-teardown`) meets the design of it.
3. **Turn telemetry into judgment.** SLOs with a hand-computed error budget, burn-rate alarms that page on *symptoms*, and a layered dashboard, then prove the whole thing works by breaking something on purpose.

---

## Per-service traps and the "why"

### S13-rest: notify, canary, reconciler
- **notify (S13.8):** consumes `notify-q` (batch 10, `ReportBatchItemFailures`); drops `synthetic=true` before side-effects. Its queue has been accumulating since Session 4, so expect it to drain a backlog on first deploy (predict roughly how many messages are waiting). Partial-batch failure must be exact and unit-tested (1 failure in 10 → exactly that messageId).
- **canary (S13.10):** sends a signed synthetic event (`synthetic=true`), which fraud-worker and notify **drop before side-effects** and archiver **keeps** under an `events-synthetic/` prefix, so your synthetic traffic doesn't pollute the ledger but *is* auditable. Also GETs `/healthz` and **tolerates its absence** (layer 30 may be torn down; that's *not* a canary failure; log and skip). Emits `CanaryIngestOk` (0/1) + `CanaryIngestLatencyMs`. This is your availability SLI source.
- **reconciler (S13.11):** for yesterday UTC, counts archive events vs GSI2 items across statuses; emits `ReconciliationDrift` (absolute count). **Small drift is expected** (velocity scoring is racy, S21.11): WARN only above a documented threshold, not on every off-by-one. This is the "money correctness" watcher.

### S23 EventBridge Scheduler
- **`lf-canary-5m`** (`rate(5 minutes)`), state driven by TF var `canary_enabled`. **Decision:** `decisions/canary-schedule.md` (default-off vs always-on; do the ~8,640/mo arithmetic; my lean is always-on so the availability SLO is real). Dedicated scheduler role with `lambda:InvokeFunction` on **that one function** (least privilege, not `*`).
- **`lf-reconciler-daily`** (`cron(30 7 * * ? *)` UTC = 01:30 Monterrey), always enabled.
- **Verify S23.3:** toggle the canary via `terraform apply -var canary_enabled=true` **only**, no console toggling (G1). This is a nice small drift-discipline rep.

### S24 CloudWatch: the observability core
- **EMF only, namespace `LedgerFlow`, < 10 metric streams** (S24). No `PutMetricData` in hot paths. Watch cardinality: `EventsRejected` by `reason` and `EventsIngested` by `eventType` are low-cardinality on purpose; most others are dimensionless. Adding a dimension is a cost decision (`observability-slo`).
- **Alarms map to felt symptoms** (S24): DLQ depth ≥ 1; fraud-backlog age > 300s; **two-speed burn-rate** on ingest (fast > 5%/5min, slow > 1%/1h, metric math over Errors/Invocations); canary-fail with **`treat_missing_data = breaching`** (silence = broken, the subtlety to internalize); ALB 5xx / p99; reconciliation drift; Lambda throttles. All → `lf-alerts`.
- **SLO doc `docs/slos.md` (S24.3):** ingest availability 99.5%/30d (SLI = canary success rate), ingest p99 < 500ms, event→ledger p95 < 60s. **Do the error-budget arithmetic by hand once**: 0.5% of 30 days ≈ 216 min. This hand-calc is the point of the requirement.
- **Dashboard `lf-overview` (S24.1):** three rows = your L1/L2/L3 model (healthy-for-users / where's-the-problem / dig-in). Three **Logs Insights** queries saved *and committed to runbooks* (S24.2).
- **Tracing (S24.4):** `decisions/tracing.md` (ADOT sidecar vs OTel SDK on the ECS services; both OTel→X-Ray; X-Ray SDK is maintenance-mode). Lambdas use active tracing. **The real work is `traceparent` propagation across SNS/SQS** (message attributes → span links in consumers), set up back in S11.3. Deliverable: one end-to-end trace screenshot API GW → ingest → fraud-worker → DynamoDB.

---

## The capstone: S24.5 (observability proving itself)

Revoke `fraud-worker`'s `dynamodb:PutItem` with a one-line Terraform change. This is the whole thesis of the observability half in one exercise, and a **predict-before-test** item:

- **Predict first:** *which* alarm fires and *how fast?* (Reason it through: the worker now fails every write → stops deleting messages → fraud-q oldest-message age climbs past 300s → `lf-fraud-backlog-age` fires. Expected: < 10 min.)
- Then apply, watch, and follow the runbook `docs/runbooks/backlog-growing.md` from the alarm email → CloudTrail/IAM → the exact `PutItem` denial. Revert.

If the alarm fires and the runbook leads you to the cause, your observability is real. Write the runbook *before* you need it.

---

## Predict-before-test targets (`my_log.md` first)

1. **notify backlog drain:** roughly how many messages are waiting in `notify-q` from prior sessions, and how fast notify clears them.
2. **canary latency:** predict `CanaryIngestLatencyMs` p50/p95 for the always-on ingest path.
3. **S24.5 capstone:** which alarm fires, and in how many minutes, after revoking `PutItem` (the big one).
4. **reconciler drift:** predict the typical `ReconciliationDrift` magnitude given the racy velocity scoring; is it within your WARN threshold?

---

## Verify checklist

- [ ] **S23.3:** canary enable/disable via `terraform apply -var canary_enabled=...` only (no console).
- [ ] **S24 metrics:** EMF only, < 10 custom streams, no `PutMetricData` in hot paths.
- [ ] **S24.3:** `docs/slos.md` exists with the three SLOs and the **hand-written** error-budget arithmetic.
- [ ] **S24.1/24.2:** `lf-overview` dashboard with L1/L2/L3 rows; three Logs Insights queries saved and committed to runbooks.
- [ ] **S24.4:** one end-to-end trace (API GW → ingest → fraud-worker → DynamoDB) captured; `traceparent` propagates through SNS/SQS.
- [ ] **S24.5 (capstone):** revoking `PutItem` fires `lf-fraud-backlog-age` in < 10 min (predicted first); the runbook leads from email to root cause; reverted.
- [ ] Canary-fail alarm uses `treat_missing_data = breaching`.

## Artifacts to leave behind

- **`docs/slos.md`:** with the by-hand error budget (this is a portfolio piece).
- **`docs/runbooks/backlog-growing.md`:** the S24.5 runbook (email → CloudTrail → IAM cause).
- **The end-to-end trace screenshot** and the three committed Logs Insights queries.
- **ADRs:** canary-schedule (S23.1), tracing (S24.4).
- **`my_log.md`:** the four predictions with actuals; the S24.5 timing especially.

## Definition of done

The fan-out is complete (notify/canary/reconciler live); metrics are EMF and under budget; SLOs are documented with a hand-computed error budget; burn-rate + symptom alarms fire correctly; the dashboard and saved queries exist; one end-to-end trace is captured; and the S24.5 capstone proves a real failure is caught by a symptom alarm and traced to its cause through your telemetry.

---

## Next

Session 7 (spec's "Session 14+") is the **final exam**: **S26** IAM hardening pass (Access Analyzer, the permission-boundary exercise, the 30-min policy-evaluation read) and **S27** resilience: the five game days, the load test, and the DR drill (destroy *everything*, rebuild, target RTO < 1h). This is where the project becomes portfolio evidence. Brief: `sessions/session-07.md`.
