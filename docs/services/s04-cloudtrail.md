# S04: CloudTrail

**Layer:** 00-org (management account) · **Session:** 2 · **Concept:** `concepts/identity-accounts-iam.md` (triage), `concepts/cost-and-teardown.md`

## Purpose
The audit backstop: a tamper-evident record of every control-plane call across both accounts. This is your forensic ground truth when Terraform, IAM, or a seeded fault confuses you.

## Requirements that carry hidden depth
- **It's an *organization* trail from the management account (4.1):** multi-region, org-wide, capturing **both** accounts into **one** bucket. Created in management, not per-account.
- **Management events only (4.1):** **data** events (every S3 object op, every DynamoDB item op) cost money and generate huge volume you don't need. Management-events-only keeps the trail cheap (see `cost-and-teardown`). Turning on data events is a slow-leak cost mistake.
- **The org-trail bucket policy differs from single-account (4.2):** this is the trap. An org-trail destination bucket policy must authorize the org's **member** accounts to write, not just the management account. Paste a single-account CloudTrail bucket policy and delivery from `mora-dev` silently fails. Bucket `lf-audit-<mgmt-acct>`, SSE-S3, BPA, 90-day expiry.
- **Log file validation on (4.1):** makes the trail tamper-evident (digest files); an interview-grade "how do you know logs weren't altered" answer.

## What the Verify is really testing
**4.3, run one `aws cloudtrail lookup-events ... EventName=CreateBucket` and read the output.** It's a *skill rep*, not a pass/fail: you're learning the tool you'll reach for whenever Terraform does something unexpected (it's step 6 of the `AccessDenied` triage in `identity-accounts-iam`). **Predict-before-test:** how long until a just-created resource's event shows up? (CloudTrail delivery has a lag; predict the minutes.)

## Cross-links
- Using CloudTrail in denial triage → `concepts/identity-accounts-iam.md`.
- Why management-events-only → `concepts/cost-and-teardown.md`.

## Done when
Org trail delivers events from **both** accounts to one validated bucket; you've run and read a `lookup-events` query with a predicted lag.
