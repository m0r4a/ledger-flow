# DynamoDB & single-table design

DynamoDB is where the ledger lives, and it's the service most likely to fight your instincts, because it is *not* a relational database and punishes you for treating it like one. The mental switch: **you do not model entities and then query them; you enumerate your access patterns first and design keys so each one is a single, cheap lookup.** Cassandra is your closest prior (partition key + clustering/sort key), so lean on that, but DynamoDB is stricter and more managed.

## The data model: items, partition key, sort key

- A **table** holds **items** (rows). Each item is a bag of attributes; there is **no fixed schema** beyond the key.
- The **primary key** is either just a **partition key (PK)**, or a **partition key + sort key (SK)**, a *composite* key. The PK decides which physical partition the item lives on; the SK orders items *within* a partition.
- The two core operations:
  - **`GetItem`:** fetch one item by full primary key. O(1), cheapest.
  - **`Query`:** fetch a *range* of items sharing one PK, optionally filtered/bounded by SK (`begins_with`, `between`, `>`…). This is the workhorse: one partition, many related items, in sorted order.
- **`Scan`** reads the *whole table*. It is the anti-pattern: expensive, slow, and a sign you modeled wrong. The spec treats a Scan in a hot path as a finding.

**Map to your world:** PK ≈ Cassandra partition key (which node/partition), SK ≈ clustering column (ordering within the partition), `Query` ≈ a partition read with a clustering-range predicate. The instinct that transfers: *design the key for the read you need, because there are no ad-hoc joins to bail you out.*

## Single-table design: the part that feels wrong at first

Coming from RDBMS you'd make a `payments` table, an `events` table, a `merchants` table, and join them. DynamoDB has **no joins**, and a `Query` only reads *one* partition. So the idiom is the opposite: **put multiple entity types in one table**, and design the PK/SK so the items you need *together* share a partition and come back in **one `Query`**.

- PK/SK are **generic** (often literally named `PK`/`SK`), holding *composed* values like `PK = PAYMENT#<id>`, `SK = EVENT#<timestamp>` or `SK = METADATA`. Different entity types use different prefixes in the same attributes.
- A single `Query` on `PK = PAYMENT#123` can return the payment's metadata item *and* all its event items together, pre-sorted; the "join" is done at write time by co-locating them.

This is genuinely disorienting the first time. The payoff is that every access pattern becomes one indexed read with predictable single-digit-millisecond latency, at any scale. The cost is that **adding a new access pattern later can require a new index or a data migration**, which is exactly why you enumerate access patterns *before* choosing keys.

## GSIs: more access patterns without more tables

You often need to read the same data a *second* way ("all payments for merchant X," "all events in status PENDING"). A **Global Secondary Index (GSI)** is a *reprojection* of the table under a different PK/SK; DynamoDB maintains it for you asynchronously.

- A GSI has its **own** PK/SK drawn from item attributes, and you `Query` it just like the base table.
- **You grant IAM on the GSI ARN separately:** a policy that allows `dynamodb:Query` on the table but not on `.../index/GSI1` will fail GSI queries (a classic least-privilege miss; see `least-privilege`).
- GSIs are **eventually consistent** (the reprojection lags the base write slightly) and have their **own** throughput/cost. LSIs (local secondary indexes) exist too but are rarer and must be defined at table creation; the spec uses GSIs.

Rule of thumb: **one table, a handful of well-chosen GSIs, zero Scans.** If you're reaching for a third GSI, re-examine whether your key design is right.

## Money as integer cents: non-negotiable

Financial values are stored as **integer cents (or smaller units)**, never floats. Two independent reasons:

1. **Floats lose precision:** `0.1 + 0.2 ≠ 0.3` in binary floating point, which is catastrophic for a ledger that must reconcile to the penny.
2. **DynamoDB's `Number` type is a precise decimal**, but you still avoid float *representation* end-to-end (in Go, in JSON, in the item) so no layer silently rounds.

Integer cents also keep item size down, which matters because DynamoDB rounds capacity **up** to the next unit per item, so smaller items mean cheaper writes. This is a spec invariant, and getting it wrong is the kind of bug that passes every test until a reconciliation is off by a cent.

## Capacity mode: on-demand (and why)

- **On-demand:** you pay per request unit; the table scales to zero when idle and up automatically under load. No capacity planning.
- **Provisioned:** you pre-buy read/write capacity units (with optional autoscaling); cheaper at steady high volume, but you pay for idle capacity.

The spec uses **on-demand** because the workload is spiky and mostly idle: you don't want to pay for provisioned throughput on a table that sees a handful of writes between sessions, and you don't want to babysit autoscaling. This is the same "scales to zero, pay-per-use" logic that keeps the whole serverless layer cheap enough to leave running (see `cost-and-teardown`). It's a `[you decide]`-adjacent call worth being able to defend: on-demand trades a higher per-request price for zero idle cost and zero capacity ops.

## Conditional writes: correctness, not just concurrency

`PutItem`/`UpdateItem` accept a **condition expression** that must hold or the write is rejected with `ConditionalCheckFailedException`. This is the backbone of two things:

- **Idempotency:** `attribute_not_exists(PK)` makes "insert this event once" safe under at-least-once delivery (the mechanism detailed in `messaging-fanout`). A failed condition on a duplicate is *success*, not an error.
- **Optimistic concurrency:** condition a write on the item's current version/state so two concurrent updates can't clobber each other; the loser retries. This is how you get correctness without locks.

Conditional writes are *the* DynamoDB feature that turns "at-least-once, concurrent" chaos into a correct ledger. Understand them before writing the ledger consumer.

## Consistency, transactions, streams: know they exist

- **Read consistency:** base-table reads can be **eventually** (default, cheaper) or **strongly** consistent (`ConsistentRead=true`); GSI reads are *always* eventually consistent. Choose deliberately: a ledger read-after-write may need strong consistency.
- **Transactions** (`TransactWriteItems`): all-or-nothing across up to 100 items, at ~2× the cost. Use when a single logical change spans items that must commit together.
- **DynamoDB Streams:** an ordered change log of the table you can trigger a Lambda from (event-driven reactions to writes). The spec uses this shape for downstream reactions; know it's the "CDC of DynamoDB."
- **PITR (point-in-time recovery)** was **dropped** in the audit (S10.1): it's a paid feature that was untested, and the project's recovery story doesn't depend on it. Knowing *why it was dropped* (pay-but-never-verify is worse than not having it) is the lesson, not the feature.

## Failure modes to expect

- **Reached for a Scan / a filter that scans** → the access pattern wasn't designed in; add a GSI or rethink keys, don't paper over it with a `FilterExpression` (filters run *after* the read and still cost you the full read).
- **GSI query denied** → IAM policy grants the table ARN but not the index ARN.
- **"Duplicate" write throwing an error** → you're treating `ConditionalCheckFailedException` as a failure instead of as "already done."
- **Hot partition** → a PK that concentrates traffic (e.g. keying by a low-cardinality value) throttles one partition while others idle; the fix is a higher-cardinality/composite key.
- **Off-by-a-cent reconciliation** → a float sneaked in somewhere in the pipeline.
- **Item too large / capacity spikes** → bloated items; another reason for integer cents and lean attributes.

## Primary sources

- **Alex DeBrie, *The DynamoDB Book*** and his blog: the canonical single-table-design treatment; the "model your access patterns first" chapters especially.
- **AWS DynamoDB Developer Guide**: the sections on core components, secondary indexes, conditional writes, and read consistency.
- **re:Invent "Advanced Design Patterns for DynamoDB" (DAT-4xx)** talks (Rick Houlihan): the classic single-table deep dives.
