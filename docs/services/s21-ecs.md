# S21: ECS (cluster, services, autoscaling, IAM)

**Layer:** 30-compute · **Session:** 5 · **Concept:** `concepts/least-privilege.md`, `concepts/messaging-fanout.md` · **Decision:** `decisions/worker-capacity.md`

## Purpose
The two containers: `ledger-api` (serves queries behind the ALB) and `fraud-worker` (consumes fraud-q, **completes the ledger write path** that Session 4 set up but couldn't finish).

## Requirements that carry hidden depth
- **Exec role vs task roles, the timing matters (21.2-21.4):** `lf-task-exec` pulls images + injects SSM secrets **before your code runs**; the *task* roles are what your code runs as. Task roles are exact: `ledger-api` = `dynamodb:GetItem,Query` on table+GSIs + `ssmmessages` + xray, *nothing else*; `fraud-worker` = `dynamodb:Put/Get/Query/Update` + `sqs` consume on `lf-fraud-q` **only** + xray. This tight scoping is the **S24.5 setup**: revoking the worker's `PutItem` later is the observability capstone.
- **`fraud-worker` correctness (21.11):** long-poll → drop `synthetic=true` → **conditional-put idempotency** → score (amount > 500 000 cents → +40; > 3 events/customer/60s → +30; ≥ 50 → FLAGGED) → write TXN → delete. SIGTERM graceful drain < 25s; `ChangeMessageVisibility` to extend a slow message. **Velocity scoring is best-effort under concurrency**: documented, *not* serialized; idempotency stays exact regardless (conditional write, not read-then-count).
- **Capacity: Fargate vs Spot (21.8, [you decide]):** the worker is interruption-tolerant *because* of drain + idempotency + backlog autoscaling. Prove that chain, then choose (`decisions/worker-capacity.md`). `ledger-api` stays on-demand.
- **Autoscaling on backlog-per-task (21.9):** `ApproximateNumberOfMessagesVisible / RunningTaskCount` via metric math, target 30, 1→3. Scaling on a *derived* signal (backlog per worker), not raw queue depth, is the senior touch.
- **Deployment circuit breaker + rollback (21.7):** a bad deploy auto-rolls-back; CI fails the job if it triggers (21.12). `readonlyRootFilesystem = true` on both (anything writing to disk must use a mount).

## What the Verify is really testing
**21.13:** S16.3/16.4 pass; **kill-one-task-under-load → zero 5xx**; **500-message flood → scales to 3, drains, returns to 1**. **Predict-before-test:** the zero-5xx claim, and the **drain time via Little's Law** (backlog ÷ (workers × throughput)) *before* the flood; this previews GD2.

## Cross-links
- Per-task least privilege + the PassRole/PassedToService from CI → `concepts/least-privilege.md`, `services/s06-github-oidc-ci.md`.
- Spot safety reasoning → `decisions/worker-capacity.md`.
- Idempotency + visibility timeout → `concepts/messaging-fanout.md`, `concepts/dynamodb-single-table.md`.

## Done when
Both services run; `fraud-worker` completes the write path with exact idempotency; autoscaling + circuit breaker work; capacity choice ADR'd; the kill-task and flood Verifies pass with predictions logged.
