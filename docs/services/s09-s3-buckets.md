# S09: S3 buckets

**Layer:** bootstrap / 00 / 10 · **Session:** 4 (buckets) · **Concept:** `concepts/least-privilege.md`, `concepts/cost-and-teardown.md`

## Purpose
The full bucket inventory: state, audit, archive, status. Each with a deliberate config that encodes a security or cost lesson.

## Requirements that carry hidden depth
- **All four Block-Public-Access flags true on *every* bucket (9.1):** non-negotiable, belt-and-suspenders with the account-level BPA (S02.2). Public S3 is the classic breach headline; this is the reflex that prevents it.
- **Archive denies non-TLS (9, `lf-archive`):** bucket policy `Deny` when `aws:SecureTransport=false`. A **guardrail-deny** (a Deny that survives future Allow edits; see `least-privilege`).
- **Hive-style archive keys (9.2):** `events/year=YYYY/month=MM/day=DD/<uuid>.ndjson`. Partition-shaped so Athena can query it directly (stretch X3). The archiver Lambda writes these.
- **Status bucket: OAC `SourceArn`, no website mode (9, `lf-status`):** bucket policy allows `s3:GetObject` **only** to the CloudFront distribution via Origin Access Control's `AWS:SourceArn` condition. The bucket stays private; CloudFront is the only reader. (Bucket in layer 10, distribution later.)
- **Lifecycle per bucket:** archive → STANDARD_IA at 30d, expire 180d; audit expire 90d; state keeps 30 noncurrent versions. Storage creep is a slow cost leak; lifecycle rules cap it.

## What the Verify is really testing
**9.3, direct bucket URL → 403, CloudFront URL → 200.** It proves the status bucket is genuinely private and *only* reachable through the distribution: the OAC `SourceArn` pattern working. (The 200 half comes once CloudFront exists in Session 5.) **Predict** both status codes.

## Cross-links
- The OAC `SourceArn` "only this caller" pattern → `concepts/least-privilege.md`.
- Lifecycle/storage cost → `concepts/cost-and-teardown.md`.
- Distribution side → `services/s22-cloudfront.md`.

## Done when
Every bucket is BPA-locked with its lifecycle; archive denies non-TLS; the status bucket is private (403 direct) pending CloudFront.
