# Decision: canary schedule (default-off vs always-on)

**Spec ref:** S23.1 (also S13.10, S24) · **ADR:** yours to write · **Spec instruction:** "do the arithmetic first."

## The decision

The canary Lambda runs on `rate(5 minutes)` via EventBridge Scheduler, gated by a Terraform variable `canary_enabled` (default **false**). Do you leave it default-off (enable only during sessions/game days) or flip it **always-on**?

## Do the arithmetic first (the spec insists)

- `rate(5 minutes)` = 12/hour × 24 × 30 ≈ **8,640 invocations/month**.
- Canary Lambda: 128 MB, short duration. Even without free tier, 8,640 invocations of a sub-second 128 MB function is **cents/month**, and it's within the Lambda free-tier allowance anyway.
- The EventBridge Scheduler invocations themselves are effectively free at this rate.
- But the canary emits EMF metrics (`CanaryIngestOk`, `CanaryIngestLatencyMs`), and those are custom metric streams (~$0.30/mo each after free tier, see `concepts/cost-and-teardown.md`). They exist whether the canary runs 8,640 times or 100 times; the *invocation* count barely changes cost, the *metric streams* are the standing cost, and they're already in your <10 budget.

So: **money is not the deciding factor.** The real question is what the canary is *for*.

## Options

| Option | For | Against |
|---|---|---|
| **Default-off** (spec default) | No noise/alarms when you're not around and the stack is intentionally down; you enable it deliberately for a session or game day | You get **no availability signal between sessions**: the whole point of a canary is continuous measurement, and default-off throws that away |
| **Always-on** | Real continuous synthetic monitoring; the SLO's availability SLI (canary success rate, S24.3) is only meaningful if the canary runs continuously; you'd catch a serverless-path regression *between* sessions | The `lf-canary-fail` alarm (with `treat_missing_data=breaching`) will fire when the always-on ingest path genuinely breaks, which is correct, but you must actually want to be paged |

## The subtlety that resolves it

The canary tests the **always-on serverless ingest path** (API GW → ingest → SNS), which is *up 24/7 by design*; it does **not** depend on the session-only compute layer. In fact S13.10 has the canary *tolerate* the layer-30 `/healthz` being absent (that's not a failure, just log and skip). So "the stack is down between sessions" is **not a reason to disable it**: the part it monitors is never down. That argues for always-on.

## My lean

**Always-on.** A canary you only run during sessions isn't really monitoring; it's a manual test with extra steps, and it makes the availability SLO fictional (you can't claim 99.5%/30d from a probe that ran 6 hours that month). The path it watches is up 24/7, the cost is trivial and already accounted for in the metric-stream budget, and catching a between-sessions regression is exactly the value. The legitimate counter: if you don't want *any* alert firing while you're not actively working the project, default-off is the "quiet inbox" choice, but then don't claim a continuous availability SLO. Decide, and make the SLO doc honest about it.

## Interview angle

"How do you measure availability?" The strong answer is "a synthetic canary running continuously, feeding the SLI," and it only holds if the canary is always-on. This ADR is you deciding whether your SLO is real or aspirational.

## Write the ADR

Record: the invocation arithmetic (~8,640/mo ≈ free), that the real standing cost is the EMF metric streams (already budgeted), the fact that the monitored path is always-on, your choice, and the consequence for the availability SLO's validity.

## Primary sources

- EventBridge Scheduler docs (`rate()` expressions, schedule state).
- `concepts/observability-slo.md` (SLI/SLO, synthetic monitoring, `treat_missing_data`).
- Lambda pricing + free tier (do the sum yourself, don't trust this page's numbers blindly).
