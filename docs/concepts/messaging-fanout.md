# Messaging: SNS → SQS fan-out, delivery & idempotency

This is the spine of the ingest path: a webhook arrives, and its event has to reach several independent consumers (ledger writer, fraud scorer, archiver, reconciler) *durably*, so that one slow or broken consumer never blocks the others and nothing is lost. AWS's answer is **SNS for fan-out, SQS for durable per-consumer buffering**, i.e. SNS→SQS. You know the shapes from ActiveMQ (your external broker at work); the differences are where the learning is.

## Why not just SNS, or just SQS?

- **SNS alone** is push pub/sub: it delivers a message to each subscriber *once, best-effort-with-retries*. If a subscriber is down when SNS tries (and exhausts retries), that message is **gone** for that subscriber; there's no buffer holding it. Fine for "notify me," wrong for "must process every payment event."
- **SQS alone** is a single durable queue with one logical consumer group. It buffers beautifully but doesn't *fan out*: you'd have one queue and every consumer competing for the same messages, so each message goes to exactly one of them, not all.
- **SNS → SQS** composes the two: SNS fans the message out to *N* SQS queues (one per consumer), and each queue durably holds that consumer's copy until it successfully processes and deletes it. Slow ledger writer? Its queue backs up; the archiver is unaffected. This is the durable-fan-out pattern, and it's the default answer to "several services each need every event."

**Map to your world:** in ActiveMQ you'd get similar fan-out with a **topic** and a **durable subscription per consumer**: the durable sub is what makes the broker hold messages for an offline consumer. SNS→SQS is that idea split into two managed services: SNS is the topic, each SQS queue is a durable subscription that also happens to be independently scalable and independently monitorable.

## Standard vs FIFO, and why this project uses Standard

SQS/SNS come in two flavors:

- **Standard:** effectively unlimited throughput, **at-least-once** delivery (rare duplicates happen), **best-effort ordering** (mostly in order, not guaranteed).
- **FIFO:** strict ordering within a *message group*, **exactly-once** processing, but far lower throughput and more constraints.

The spec uses **Standard** and *engineers the application to tolerate its two realities* (duplicates and reordering) rather than paying FIFO's cost. That's the senior move: **at-least-once + idempotent consumers** is cheaper, faster, and more resilient than reaching for exactly-once delivery. The exactly-once guarantee you actually want lives in *your* code (idempotency), not in the broker. Internalize that trade; it's a recurring interview theme.

## At-least-once means duplicates are normal, not exceptional

Standard SQS can deliver the same message more than once for ordinary reasons: SNS retried, a visibility timeout expired mid-processing, or the delete didn't register. **This is not a failure mode to prevent; it's a contract to design around.** Two consequences the spec builds on:

- Every consumer must be **idempotent**: processing the same event twice must have the same effect as processing it once.
- "Processed" and "deleted from the queue" are two steps; a crash between them causes a redelivery. Your idempotency is what makes that safe.

## Idempotency via conditional writes (the ledger's exactly-once)

The ledger writer's job is "record this payment event once, even if I see it three times." The mechanism is a **conditional `PutItem`** into DynamoDB keyed by the event's unique ID, with a condition like `attribute_not_exists(PK)`:

- First delivery: the item doesn't exist, the condition passes, the write lands.
- Duplicate delivery: the item already exists, the condition fails with `ConditionalCheckFailedException`, and the consumer treats that specific error as **"already done, success,"** deletes the message, and moves on.

That's how you get exactly-once *effects* on top of at-least-once *delivery* without FIFO. The subtlety the spec calls out (S21): the **idempotency** guarantee is exact, but **velocity/fraud scoring** (which counts events in a window) is only *best-effort under concurrency*, because two duplicates processed simultaneously can both read the pre-write count. Knowing which guarantees are exact and which are approximate (and documenting it) is the staff-level distinction.

## Visibility timeout: the ack model, and the 6× rule

SQS has no ack/nack session like ActiveMQ. Instead: when a consumer *receives* a message, SQS makes it **invisible** to other consumers for the **visibility timeout**. The consumer must `DeleteMessage` before the timeout expires to signal success. If it doesn't (crash, or just too slow), the message becomes visible again and gets redelivered.

Two failure modes fall directly out of this, and both are on the spec's radar:

- **Timeout too short** → a message that's still being processed reappears and gets picked up by a *second* consumer, so it's processed twice concurrently (extra load, and it stresses your idempotency). The rule of thumb the spec uses: **visibility timeout ≈ 6× the consumer's Lambda timeout**, giving retries and slow runs headroom before redelivery.
- **Timeout too long** → a genuinely-crashed message sits invisible for ages before anyone retries it, inflating latency.

This is a behavioral predict-before-test area: before you tune the timeout, predict what happens to a message when the consumer takes longer than the timeout.

## Dead-letter queues and the poison-message problem

Some messages can *never* succeed: a malformed payload, a bug, a referenced record that will never exist. Without a backstop, such a **poison message** is redelivered forever, burning invocations and blocking progress. The fix is a **dead-letter queue (DLQ)**: configure a `maxReceiveCount` (redrive policy) on the main queue, and after that many failed receives SQS moves the message to the DLQ automatically.

The DLQ turns "silent infinite retry" into "an observable pile of failures you can alarm on and inspect." The spec's discipline:

- Every consumer queue has a DLQ.
- The **DLQ depth is alarmed:** a non-empty DLQ is a signal, not a place messages go to die quietly.
- **Redrive:** once you've fixed the cause, you move messages from the DLQ back to the source queue to reprocess (SQS has a built-in redrive-to-source action). This is a game-day exercise: break a consumer, watch messages land in the DLQ, fix it, redrive, confirm they process.

**Map to your world:** this is ActiveMQ's DLQ + redelivery policy, but you configure `maxReceiveCount` instead of a broker redelivery-policy, and "redrive" replaces manually moving messages off `ActiveMQ.DLQ`.

## The queue policy: who is allowed to enqueue (confused-deputy again)

An SQS queue subscribed to SNS needs a **resource policy** that allows `sqs:SendMessage` from the `sns.amazonaws.com` service principal, **but only when `aws:SourceArn` equals your topic ARN.** Without that condition, any SNS topic that learns your queue's ARN (including one in another account) could be authorized to send to it. This is the confused-deputy pattern from `identity-accounts-iam`, and the queue policy is where you'll write it for real. It's a common Verify miss: the subscription looks wired but messages don't flow because the queue policy is missing or the `SourceArn` is wrong.

## Batching, long polling, and cost/latency levers

- **Batching:** SQS bills per request, and a request can carry up to 10 messages; a Lambda event-source mapping can hand your function a batch. Batching is simultaneously a **cost** lever (10× fewer requests) and a **throughput** lever, at the price of a little latency. Know that partial-batch failures need handling so one bad message in a batch of 10 doesn't force all 10 to redeliver (report the specific failures back).
- **Long polling** (`WaitTimeSeconds > 0`) avoids the cost and noise of empty short-poll receives by letting a `ReceiveMessage` wait for a message to arrive. Prefer it.
- **Message size:** SQS caps at 256 KB; larger payloads use the S3 "extended client" pattern (pointer in the message, body in S3). Your webhook events are small, so this stays a fact-you-know, not a thing-you-build.

## Failure modes to expect (and practice)

- **Messages don't arrive at a queue** → check the SNS subscription *and* the queue's resource policy `SourceArn` condition.
- **Everything processed twice** → visibility timeout too short, or a consumer that isn't deleting on success; confirm idempotency actually holds.
- **DLQ filling up** → a poison message or a systemic consumer bug; inspect one message, fix, redrive.
- **One consumer's backlog grows, others fine** → exactly what fan-out is supposed to isolate; scale/fix that consumer without touching the rest. (This is the S24.5 exercise: revoke the fraud worker's `dynamodb:PutItem`, watch *only its* queue back up, trace to the IAM change.)
- **Duplicate suppression "works" but counts are slightly off** → velocity scoring under concurrency; that's the documented best-effort boundary, not a bug to chase into the ground.

## Primary sources

- **Amazon SQS FAQs** and the **SQS Developer Guide** sections on visibility timeout, DLQs/redrive, and long polling: unusually clear.
- **Amazon SNS Developer Guide**, the "fanout to SQS" and message-filtering sections.
- The **Amazon Builders' Library** article on **avoiding duplicate work / idempotency**, and anything from Marc Brooker on queues and back-pressure.
- DeBrie / AWS docs on **conditional writes** for the idempotency mechanism (cross-ref `dynamodb-single-table`).
