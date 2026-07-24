# Decision: fraud-worker capacity (Fargate vs Fargate Spot)

**Spec ref:** S21.8 (also 21.1, 21.11) · **ADR:** yours to write · **The spec's needling question:** "the worker is interruption-tolerant by design, *is it really?*"

## The decision

The `fraud-worker` ECS service (desired 1, autoscale 1→3) can run on **Fargate** (on-demand, stable) or **Fargate Spot** (~70% cheaper, but AWS can reclaim the task with a **120-second** SIGTERM warning). The `ledger-api` service stays on-demand (it's user-facing); this decision is only about the worker.

## What makes it interesting

The spec *dares* you to justify "interruption-tolerant." The worker's safety on interruption depends entirely on machinery you already built:

- **Graceful drain on SIGTERM** (S21.11): stop receiving, finish in-flight messages, exit in < 25 s, comfortably inside Spot's 120 s warning.
- **At-least-once + idempotency**: even if a task dies *mid-message* without deleting it, the message reappears after the visibility timeout and another worker reprocesses it, and the conditional-write idempotency means reprocessing is safe (no double-write).
- **Autoscaling on backlog-per-task**: if Spot reclaims a task, the backlog metric rises and App Auto Scaling launches a replacement.

So the honest answer to "is it really interruption-tolerant?" is **yes, *because* of drain + idempotency + backlog autoscaling**, and articulating that chain is the whole point of the ADR.

## Options

| | Fargate (on-demand) | Fargate Spot |
|---|---|---|
| **Cost** | Full price | ~70% cheaper |
| **Interruption** | None (barring rare platform events) | AWS may reclaim with 120 s notice |
| **Safe here?** | Always | Yes *if* drain + idempotency + autoscaling hold |
| **What it tests** | nothing new | whether your resilience story is real |

## The failure question to answer *before* deciding

"What happens to an in-flight message on SIGTERM?" Walk it: SIGTERM → stop `ReceiveMessage` → finish the message(s) you hold → delete them → exit. If you exit *before* deleting, the message's visibility timeout lapses and it's redelivered, which is safe because of idempotency, but it *is* a reprocess. If a message needs > 60 s you already `ChangeMessageVisibility` to extend it (S21.11). Confirm this chain in your head; that's the acceptance criterion for choosing Spot.

## My lean

**Fargate Spot.** This worker was *designed* to tolerate exactly this, and choosing Spot is what makes that design mean something (plus it's a real cost lesson and a genuine resilience rehearsal). Keep `ledger-api` on-demand. The conservative counter: at this scale the dollar difference is pennies, so if you'd rather remove a variable while first getting ECS working, start on-demand and switch to Spot once drain is proven, and *say* that's why. Either way, the ADR must contain the SIGTERM walk-through.

## Interview angle

"When is Spot safe?" is a classic. The staff answer isn't "for stateless things." It's "when the work is idempotent and re-drivable and the shutdown is graceful within the interruption warning." This ADR is you proving you can reason about it from the message's point of view.

## Write the ADR

Record: the interruption model (120 s warning), the drain + idempotency + autoscaling chain that makes reclaim safe, the in-flight-message walk-through, your choice, and why `ledger-api` stays on-demand regardless.

## Primary sources

- ECS on Fargate Spot docs (interruption behavior, the SIGTERM + 120 s warning).
- ECS task lifecycle / `stopTimeout` and container `SIGTERM` handling.
- Cross-refs: `concepts/messaging-fanout.md` (visibility timeout, at-least-once), `concepts/dynamodb-single-table.md` (conditional-write idempotency).
