# S27: Resilience, game days & DR (the final exam)

**Layer:** cross-cutting · **Session:** 7 · **Concept:** all of them · **Predict-before-test: fully in force (every game day + the DR RTO).**

## Purpose
Prove you can *operate* the system: break it safely, measure it, and rebuild it from nothing. This is where the repo becomes portfolio evidence; the honest write-ups matter as much as the actions.

## The five game days (R9.1): hypothesis → method → expected alarms → observed → learnings
Write the first two columns *before* touching anything.

- **GD1:** kill 1 of 2 api tasks under load. Predict: zero 5xx (desired=2, deregistration delay, health checks).
- **GD2:** fraud-worker down 30 min under load. Predict: backlog alarm fires, no loss, convergence on restart, and **drain time via Little's Law** (backlog ÷ (workers × throughput)), *the arithmetic before the restart* (S27 senior note).
- **GD3:** poison-pill flood (50 malformed). Predict: DLQ alarm, then clean **redrive-to-source** after the fix (native SQS, no requeue script).
- **GD4:** delete the ACM validation record. Predict: what breaks and *when*? Certs don't die instantly, so this teaches renewal mechanics.
- **GD5:** simulate AZ loss (desired subnets → one AZ). Predict: capacity halves, service survives.

## The other three
- **R9.2 load test:** find the ingest ceiling: at burst, do you hit the **Lambda concurrency cap** (~50) or the **API Gateway throttle** (25 rps) first? Predict (throttle should bite first for sustained load; the cap only if service time spikes), then document the numbers. Uses the full `--chaos` loadgen.
- **R9.3 DR drill (the actual final exam):** export DynamoDB to S3 (native export, *why PITR was dropped*), `terraform destroy` **everything incl. serverless** (the one sanctioned `prevent_destroy` override), then full rebuild + restore. **Time it; target RTO < 1h.** Predict the RTO first. Data verified by the reconciler. If it works, you've genuinely learned IaC.
- **R9.4 cost retro:** after a full month, Cost Explorer **by tag**: what each layer cost, what surprised you, what you'd change at 100× traffic. Must contain a genuine surprise (often a data-transfer/cross-AZ one; `cost-and-teardown`).

## What the Verify is really testing
The acceptance criteria are honesty and repeatability: all five game days written up **including the wrong hypotheses** (worth the most); DR RTO measured and data verified; a cost retro with a real surprise. It's testing whether you can run this like an operator, not whether the system passes.

## Cross-links
- Drain/DLQ/redrive → `concepts/messaging-fanout.md`; which alarm proves each hypothesis → `concepts/observability-slo.md`; teardown/cost surprises → `concepts/cost-and-teardown.md`; the ceiling → `decisions/ingest-concurrency.md`.
- Session arc → `sessions/session-07.md`.

## Done when
Five game days executed and honestly written up; ingest ceiling known; DR drill rebuilds everything with data intact under a measured RTO < 1h; cost retro exists with a genuine surprise. That meets the whole-project Definition of Done, and you've done the hard things you set out to learn from.
