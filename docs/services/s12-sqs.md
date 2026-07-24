# S12: SQS

**Layer:** 10-serverless · **Session:** 4 · **Concept:** `concepts/messaging-fanout.md`

## Purpose
Durable per-consumer buffering: three consumer queues + three DLQs. This is what makes one slow/broken consumer never block the others.

## Requirements that carry hidden depth
- **Queue policy scopes `SendMessage` to SNS with `aws:SourceArn` = the topic (12.1):** the **confused-deputy fix**, and the classic trap: without the condition, any topic that learns your queue ARN could send to it; without the *policy at all*, the subscription looks wired but messages silently never arrive. This is the single most important line in S12.
- **Visibility timeouts encode the 6× rule (12):** notify-q 60s (= 6×10s Lambda timeout), archive-q 180s (= 6×30s), fraud-q 120s (ECS worker). **Internalize why** (Lambda internal retries + batch window) rather than cargo-culting; it comes up in incident reviews (12 senior note). Too short → concurrent double-processing; too long → slow retries (see `messaging-fanout`).
- **DLQ via `maxReceiveCount=3` (12):** after 3 failed receives a poison message moves to the DLQ instead of retrying forever. DLQ retention 14d (long enough to inspect and redrive).
- **Long polling `WaitTimeSeconds=20` (12):** avoids the cost/noise of empty short-poll receives.
- **DLQ alarms (12.2):** `ApproximateNumberOfMessagesVisible ≥ 1` → `lf-alerts`. A non-empty DLQ is a *signal*, never a silent grave. (Alarm resource is S24; owned conceptually here.)

## What the Verify is really testing
No standalone Verify for S12 in isolation; it's proven via S11.5 (routing), the end-to-end flow (archiver consumes), and **12.3's redrive drill** (fix a poison message, then **redrive-to-source**, the native SQS feature, *no hand-written requeue script*). The redrive drill is exercised for real in GD3 (Session 7).

## Cross-links
- Visibility timeout, DLQ/redrive, at-least-once → `concepts/messaging-fanout.md`.
- The `SourceArn` confused-deputy reasoning → `concepts/identity-accounts-iam.md`.

## Done when
Three queues + DLQs with correct visibility timeouts and redrive; every queue policy is `SourceArn`-scoped; DLQ alarms defined; long polling on.
