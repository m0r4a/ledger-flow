# Session 4: the first end-to-end serverless flow (S07-S14)

**Covers:** the spec's "Session 4-6" block: **S07** Route 53, **S08** SSM tree, **S09** S3 buckets, **S10** DynamoDB, **S11** SNS, **S12** SQS, **S13** the *ingest* and *archiver* Lambdas, **S14** API Gateway. This is several sittings, not one; the payoff at the end is real: **a signed webhook travels API GW → ingest → SNS → SQS fan-out → archiver → S3**, entirely serverless, ≈free, and it *stays up 24/7*. This is the first time the system does something.

> Read `concepts/messaging-fanout.md` and `concepts/dynamodb-single-table.md` cover to cover before this block, plus `concepts/least-privilege.md` (you write ~6 tightly-scoped roles here) and the cost page (this is the "cents forever" layer; keep it that way). Everything here is in **layer 10-serverless** (dev account, `lf-dev`), the always-on side of the billing line.

---

## The arc (build in this order, and know why)

The order is dependency-driven; each piece is the substrate for the next:

1. **S07 Route 53 + S08 SSM:** the naming/config substrate. The hosted zone (`aws.gmora.work`) and the SSM tree (`/lf/dev/...`) are what everything else references.
2. **S09 S3 + S10 DynamoDB:** the storage substrate. Archive bucket (where events land) and the ledger table (where money lives, later).
3. **S11 SNS + S12 SQS:** the messaging spine. The topic and the three consumer queues + DLQs. This is where `messaging-fanout` becomes real.
4. **S13 ingest + archiver, S14 API Gateway:** the compute + front door that make it flow end to end.

**What the end-to-end actually reaches at the end of this block:** webhook → API GW → **ingest** (verifies HMAC, publishes to SNS) → SNS fan-out → **archive-q** → **archiver** (batches to NDJSON in S3). The **fraud-q** and **notify-q** *also fill up*, but their consumers (`fraud-worker` is ECS/Session 5, `notify` Lambda is Session 6) **don't exist yet**, so those queues sit with messages (4-day retention, fine by design). Don't be alarmed that two queues have a growing `ApproximateNumberOfMessagesVisible`; that's the fan-out waiting for its consumers. Knowing this *before* you look at the console saves a false alarm.

---

## Two real sequencing subtleties (the DAG vs the linear numbering)

The session numbers are a rough calendar; the true order is a dependency graph, and two edges cross session boundaries:

1. **You need cert A (S18) *now*, earlier than S18's session.** S14.5's webhook custom domain (`webhook.aws.gmora.work`) requires an ACM cert, and that's cert A. And `decisions/cert-placement.md` puts cert A in an **always-on layer (00 or 10)** *precisely because* this webhook domain needs it 24/7. So when you build the layer-10 webhook domain, you build cert A with it. **Decision point:** either (a) build cert A + the custom domain now (cleaner end state, and forces the DNS-validation exercise early), or (b) defer the custom domain and hit the raw API Gateway `execute-api` endpoint until Session 5, then attach the domain. Both are valid: (a) is more satisfying, (b) unblocks the flow faster. Note your choice; it's a small ADR-worthy call.
2. **DynamoDB is *created* here but its write path completes in Session 5.** S10's table + schema + GSIs land now, but the *writer* is `fraud-worker` (ECS, Session 5). So S10.6's behavioral Verify (replay one webhook 50× → exactly 1 TXN + 1 IDEM item, 49 handled `ConditionalCheckFailedException`) can't fully run until fraud-worker exists. This session you build the table and can test the **conditional-put mechanics directly** (via CLI/a scratch test); the full replay-50× end-to-end lands in Session 5. Ingest itself **does not touch DynamoDB** (S13.7); it only publishes to SNS.

Surface both of these in `my_log.md` so the "why isn't the ledger writing yet" question is already answered.

---

## Per-service traps and the "why" (session-level; per-service pages go deeper)

### S07 Route 53
- Public hosted zone `aws.gmora.work` in layer 00, **never destroyed** ($0.50/mo, `prevent_destroy`). Delegation is **4 NS records in Cloudflare** pointing at the zone's NS set (S07.2); this is the hop where DNS actually starts working.
- The app records (`api`, `status`, `webhook`) are created by their **owning layers**, not here: `webhook` A-alias → API GW (layer 10, this session); `api`/`status` come with layers 30. Alias records point at AWS resources with **no IP** (that's why they survive teardown/rebuild: everything references the *name*).
- **Predict-before-test (S07.4):** `dig +trace webhook.aws.gmora.work` and follow delegation hop by hop. You do DNS-adjacent work, so predict the delegation chain (root → `.work` → Cloudflare → Route 53) before you trace it.

### S08 SSM
- The **HMAC secret** (`/lf/dev/webhook-hmac`, SecureString) is generated **locally** (`openssl rand -hex 32`) and put with `aws ssm put-parameter`, **never in Terraform** (secrets in state = plaintext in S3; see `terraform-layers-state`). This is the G4/G5 discipline made concrete. Ingest and canary read it at cold start and cache it.
- Standard tier only (free ≤ 10k params). The `/lf/dev/tf/<layer>/<output>` subtree is the cross-layer wiring bus (written by Terraform, String type).

### S09 S3
- **All four Block-Public-Access flags true on every bucket** (S09.1), non-negotiable. The archive bucket also denies non-TLS (`aws:SecureTransport=false` → Deny), a `least-privilege` guardrail-deny in the wild.
- Archive key format is **Hive-style** (`events/year=YYYY/month=MM/day=DD/<uuid>.ndjson`, S09.2), Athena-ready for stretch X3. The archiver writes these.
- The status bucket exists here (layer 10) but its CloudFront distribution comes later; its bucket policy allows `s3:GetObject` **only** to the CloudFront distribution via OAC `SourceArn`; you'll wire that when the distribution lands.

### S10 DynamoDB
- On-demand, **PITR off** (`decisions`-adjacent; the DR drill uses export/import, not PITR, so don't pay for untested capability), TTL on `expiresAt`, deletion protection **off** (the DR drill destroys it deliberately).
- **Money as integer cents. Idempotency as conditional-put, not read-then-write.** These are the two things the spec says it'd check first in review (S10 senior note). Get the key design (PK/SK + two GSIs) from S10.2/10.3 and commit the access-pattern → query mapping as **ADR-002** (S10.4). See `dynamodb-single-table`.
- `grep -rn "Scan(" services/ functions/` must return nothing (S10.5); a Scan is a modeling failure here.

### S11 SNS + S12 SQS: the spine
- **Message contract (S11.3):** body = event JSON; attributes `eventType` and **`traceparent`** (this is how trace context crosses the async gap: the propagation problem from `observability-slo`, set up now even though tracing is polished later).
- **Filtered fan-out (S11.4):** fraud-q gets `eventType prefix payment.`; notify-q gets *only* `payment.settled`; archive-q gets everything (no filter). **Raw message delivery on.** Predict the routing (S11.5): publish one `payment.failed` → which queues receive it? (Answer: fraud + archive, *not* notify, because notify filters to `settled` only.) Predict before you check `NumberOfMessagesReceived`.
- **The queue policy is the classic trap (S12.1):** `sqs:SendMessage` allowed to `sns.amazonaws.com` **only when `aws:SourceArn` = the topic ARN**, the confused-deputy fix (`messaging-fanout` + `identity-accounts-iam`). Miss the condition and any topic could stuff your queue; miss the *policy* and messages silently never arrive. This is where "the subscription looks wired but nothing flows" comes from.
- **Visibility timeouts encode the 6× rule (S12):** notify-q 60s (=6×10s Lambda timeout), archive-q 180s (=6×30s). Internalize *why* (Lambda internal retries + batch window), don't cargo-cult (S12 senior note). fraud-q is 120s for the ECS worker.
- **Every DLQ gets an alarm** (`≥1` visible → `lf-alerts`, S12.2), conceptually owned here even though the alarm resource is S24. A non-empty DLQ is a signal, never a quiet grave.

### S13 ingest + archiver
- **All five Lambdas: `provided.al2023`, arm64, Go, single `bootstrap` binary, no VPC config** (S13.1/13.6: they touch only AWS APIs, so no-VPC = free egress + fast cold starts; contrast the ECS services which *are* in the VPC). 14-day log groups, X-Ray active tracing, structured slog with `traceId`/`providerEventId`.
- **ingest (S13.7):** constant-time HMAC compare (`hmac.Equal`) over the raw body; bad sig → **401**, bad JSON/schema → **422**, success → **202** `{"eventId":...}`. **Does not touch DynamoDB.** Reserved concurrency capped (`decisions/ingest-concurrency.md`, your ADR on the number, ~50).
- **archiver (S13.8/13.9):** SQS event-source mapping, batch 25, window 30s, **`ReportBatchItemFailures`**: a batch of 10 with 1 failure returns *exactly* that 1 messageId in `batchItemFailures` (unit-test this). Aggregates the batch into **one** NDJSON object per invocation.

### S14 API Gateway
- **HTTP API** (not REST, cheaper and sufficient), route `POST /webhook` → Lambda proxy, payload format **2.0**. `$default` stage, auto-deploy.
- **Throttle 25 rps / burst 50 (S14.3):** the wallet guard that pairs with ingest's reserved concurrency (two ceilings; see `decisions/ingest-concurrency.md`). Access logs to `/lf/apigw/ingest`, 14-day retention.
- Custom domain `webhook.aws.gmora.work` (cert A); see sequencing subtlety #1.

---

## Predict-before-test targets (`my_log.md` first)

1. **S07.4:** the `dig +trace` delegation chain for `webhook.aws.gmora.work`.
2. **S11.5:** which queues receive a `payment.failed` event (fan-out filtering).
3. **S14.6:** signed valid POST → **202 in < 500 ms p99** (measure with loadgen, 10 rps × 2 min). Predict the p99 *and* predict the unsigned-POST status (401).
4. **S10.6** (mechanics now, full run Session 5): replay one webhook 50×: predict the item count (1 TXN + 1 IDEM) and that the 49 rejects surface as handled `ConditionalCheckFailedException` (metric, not error spam).

---

## Verify checklist

- [ ] **S07.4:** `dig +trace` follows the delegation to Route 53 (predicted first).
- [ ] **S09.3:** direct status-bucket URL → 403 (CloudFront comes later; bucket stays private).
- [ ] **S10.5:** `grep -rn "Scan("` returns nothing; ADR-002 (access-pattern → query map) written.
- [ ] **S11.5:** `payment.failed` reaches fraud+archive, not notify (checked via per-queue `NumberOfMessagesReceived`).
- [ ] **S12.1:** every queue policy scopes `SendMessage` to SNS with `aws:SourceArn` = topic.
- [ ] **S13.7/13.8:** ingest returns 401/422/202 correctly and never touches DynamoDB; archiver's partial-batch failure returns exactly the failed messageId (unit-tested).
- [ ] **S14.6:** unsigned → 401; signed → 202 < 500 ms p99 (measured with loadgen; predicted first).
- [ ] **End-to-end:** a signed webhook lands as an NDJSON object in `lf-archive-<acct>/events/...`; fraud-q and notify-q accumulate messages (consumers pending, expected).

## Artifacts to leave behind

- **ADR-002** (DynamoDB schema + access-pattern mapping), and (if you built it) the cert-A-early / custom-domain sequencing note.
- **`my_log.md`:** predictions + actuals for S07.4, S11.5, S14.6; and the "fraud-q/notify-q filling is expected" note.
- The minimal **loadgen** (S25) signed-request version; S14.6 needs it. Full `--chaos` version comes before S27.

## Definition of done

Signed webhook flows end-to-end to S3 via ingest → SNS → archive-q → archiver; DynamoDB table + schema + GSIs exist (write path completes Session 5); the messaging spine fans out with correct filters and confused-deputy-safe queue policies; ingest enforces 401/422/202 with a concurrency cap; API GW throttles at 25 rps. The whole layer is ≈free and stays up.

---

## Next

Session 5 (spec's "Session 7-10") is the **container + VPC + edge** block: **S15-S22**, the locked-down VPC with no NAT, the exact VPC endpoints, security groups, ACM, ECR, the internal ALB, ECS (including `fraud-worker`, which finally completes the ledger write path), and CloudFront. Read `concepts/networking-no-nat.md` first; this is where the network is *designed to fail loudly*. Brief: `sessions/session-05.md`.
