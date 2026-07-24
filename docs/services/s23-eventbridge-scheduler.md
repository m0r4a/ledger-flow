# S23: EventBridge Scheduler

**Layer:** 10-serverless · **Session:** 6 · **Concept:** `concepts/observability-slo.md` · **Decision:** `decisions/canary-schedule.md`

## Purpose
The two time-driven triggers: the canary (continuous synthetic monitoring) and the daily reconciler (correctness check).

## Requirements that carry hidden depth
- **`lf-canary-5m` state via TF var `canary_enabled` (23.1, [you decide]):** `rate(5 minutes)`. Default-off vs always-on is a real decision: do the ~8,640/mo arithmetic (it's ≈ free; the standing cost is the EMF metric streams, already budgeted), and note the monitored path is up 24/7. My lean: **always-on**, so the availability SLO is real (`decisions/canary-schedule.md`).
- **Dedicated scheduler role, one function (23.1/23.2):** `lambda:InvokeFunction` on **that one function** only, not `*`. Least privilege even for a scheduler.
- **`lf-reconciler-daily` cron (23.2):** `cron(30 7 * * ? *)` UTC = 01:30 Monterrey, always enabled. Note the UTC-vs-local reasoning (schedule in UTC, know your offset).

## What the Verify is really testing
**23.3, toggle the canary via `terraform apply -var canary_enabled=true` *only*, no console toggling.** It's a **G1 drift-discipline** rep: even a "just flip it in the console" convenience is off-limits; state changes go through Terraform so the account never drifts from code.

## Cross-links
- Canary schedule arithmetic + SLO consequence → `decisions/canary-schedule.md`.
- The canary as availability SLI → `concepts/observability-slo.md`, `services/s13-lambdas.md`.

## Done when
Both schedules exist with dedicated single-function roles; the canary toggles only via Terraform; decision on always-on ADR'd.
