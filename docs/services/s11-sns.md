# S11: SNS

**Layer:** 10-serverless · **Session:** 4 · **Concept:** `concepts/messaging-fanout.md`

## Purpose
The fan-out topic `lf-payments`: the branch point where one ingested event splits toward every independent consumer.

## Requirements that carry hidden depth
- **Only the ingest role may publish (11.2):** `sns:Publish` is granted in the ingest role's identity policy; the topic's access policy stays default-deny-external. Least privilege at the publisher.
- **Message contract carries `traceparent` (11.3):** attributes are `eventType` and **`traceparent`**. That second one is how **trace context crosses the async gap** (SNS→SQS is a message boundary; HTTP headers don't carry through). Set it up now even though tracing is polished in Session 6; it's the propagation problem from `observability-slo`.
- **Filtered subscriptions, raw delivery on (11.4):** fraud-q: `eventType prefix payment.`; notify-q: **only** `payment.settled`; archive-q: no filter (everything). Filtering at the topic means each consumer's queue only holds what it cares about. Raw message delivery = no SNS envelope wrapping the body.

## What the Verify is really testing
**11.5, publish one `payment.failed` → fraud + archive receive it, notify does not** (check per-queue `NumberOfMessagesReceived`). It proves the subscription filters route correctly. **Predict-before-test:** which queues get a `payment.failed`? (fraud + archive; *not* notify, which filters to `settled` only.)

## Cross-links
- Why SNS→SQS for durable fan-out (vs SNS-alone) → `concepts/messaging-fanout.md`.
- The queue side and the `SourceArn` policy → `services/s12-sqs.md`.
- `traceparent` propagation → `concepts/observability-slo.md`.

## Done when
Topic exists with SSE; only ingest can publish; the three filtered subscriptions route a test `payment.failed` to fraud+archive but not notify (predicted first).
