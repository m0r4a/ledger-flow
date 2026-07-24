# S22: CloudFront + status page

**Layer:** 30 (default) or 10 · **Session:** 5 · **Concept:** `concepts/cost-and-teardown.md` · **Decision:** `decisions/cloudfront-layer.md`

## Purpose
The public edge for the static status page: the one thing meant to be reachable from the open internet (unlike the internal query API).

## Requirements that carry hidden depth
- **Origin Access Control, not legacy OAI (22.1):** OAC is the current mechanism; the status bucket's policy allows `s3:GetObject` **only** to the distribution via OAC's `AWS:SourceArn` condition (S09). The bucket stays private; CloudFront is the sole reader.
- **Layer placement is a real decision (22.3, [you decide]):** distributions take **~5 min to create/delete**, which slows every `just up/down`. Since CloudFront is **≈$0 at zero traffic**, moving it to always-on layer 10 is defensible (matches the "cheap-when-idle → always-on" heuristic). See `decisions/cloudfront-layer.md` (my lean: move to 10). Note the cert-B ripple if you move it.
- **`PriceClass_100`, `CachingOptimized`, cert B (22.1):** cheapest edge locations; managed cache policy; the us-east-1 cert from S18.

## What the Verify is really testing
**22.4, direct bucket URL → 403; `https://status.aws.gmora.work` → 200 with an `x-cache` header.** It proves the bucket is private and *only* served through CloudFront (the OAC `SourceArn` pattern), and that caching is active (`x-cache`). **Predict** both.

## Cross-links
- Layer-placement heuristic (billing shape + provisioning latency) → `decisions/cloudfront-layer.md`, `concepts/cost-and-teardown.md`.
- The bucket side (OAC policy) → `services/s09-s3-buckets.md`.

## Done when
Distribution serves the status page over HTTPS via OAC; direct bucket access is 403; `x-cache` present; layer choice ADR'd.
