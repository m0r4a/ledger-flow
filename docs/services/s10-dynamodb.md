# S10: DynamoDB

**Layer:** 10-serverless · **Session:** 4 (table) / 5 (write path) · **Concept:** `concepts/dynamodb-single-table.md`

## Purpose
The ledger, where money lives. The single most correctness-sensitive service in the project.

## Requirements that carry hidden depth
- **Money as integer cents, never floats (10.3); and idempotency as conditional-put, not read-then-write (10.4):** the spec says these are **the two things it would check first in a code review** (10 senior note). Floats lose precision and break reconciliation; read-then-write loses to race conditions. Both are invariants, not preferences.
- **Single-table, PK/SK + two GSIs (10.2/10.3):** one table holds Transaction and Idempotency items with prefixed keys (`CUST#`, `TXN#`, `IDEM#`). GSI1 = get-by-txnId; GSI2 = flagged-in-range. **Grant IAM on the GSI ARNs separately:** a policy allowing the table but not `.../index/GSI2` fails GSI queries (a common least-privilege miss).
- **On-demand, PITR off, deletion protection off (10.1):** on-demand scales to zero (no idle charge). **PITR is off deliberately:** the DR drill (R9.3) uses native export/import, so paying for point-in-time restore you never exercise is waste. Deletion protection off because the DR drill destroys the table on purpose. TTL on `expiresAt` (auto-expires idempotency records at 7d).
- **Access-pattern → query mapping as ADR-002 (10.4):** AP1-AP4 each map to a specific Query. Writing this down *is* the single-table design work; deviating from the reference schema needs a written ADR.
- **No Scan anywhere (10.5):** `grep -rn "Scan("` returns nothing. A Scan is a modeling failure (and a `FilterExpression` still scans: it filters *after* the full read).

## What the Verify is really testing
**10.6, replay one webhook 50× → exactly 1 TXN item + 1 IDEM item; the 49 rejects are handled `ConditionalCheckFailedException` (a metric, not error-log spam).** This proves exactly-once *effects* on at-least-once delivery via conditional write. **Predict** the item counts and that duplicates are success, not error. (Full run needs `fraud-worker`, Session 5; test conditional-put mechanics directly in Session 4.)

## Cross-links
- Single-table modeling, conditional writes, consistency → `concepts/dynamodb-single-table.md`.
- The idempotency ↔ at-least-once tie → `concepts/messaging-fanout.md`.

## Done when
Table + two GSIs + TTL exist; schema and access-pattern mapping ADR'd; no Scans; the replay-50× Verify passes (once the writer exists) with a logged prediction.
