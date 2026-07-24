# S18: ACM

**Layer:** 00/10 (cert A) · 30 (cert B) · **Session:** 4-5 · **Concept:** `concepts/terraform-layers-state.md` (provider aliases) · **Decision:** `decisions/cert-placement.md`

## Purpose
TLS certs for the two edges: the ALB/webhook (cert A, us-east-2) and CloudFront (cert B, us-east-1). Also the multi-provider-alias Terraform exercise.

## Requirements that carry hidden depth
- **Cert A cannot live in layer 20 (18.4, [you decide]):** it serves the **always-on** webhook custom domain (layer 10), so tearing down 20 each session would kill the 24/7 endpoint (violates G3). The real choice is 00-foundation vs 10-serverless, both always-on. The ALB (layer 30) references it **by ARN via SSM**. Write **ADR-003**; see `decisions/cert-placement.md`.
- **Cert B must be us-east-1 (18.2):** CloudFront requires it. This is the **provider-alias exercise**: a second `aws` provider `alias="us_east_1"` in layer 30 (`terraform-layers-state` → provider aliases).
- **DNS validation, fully automated (18.3):** `aws_acm_certificate` → `aws_route53_record` (`for_each` over `domain_validation_options`) → `aws_acm_certificate_validation`. The `for_each` over validation options is the idiom that trips people; get it once and it's reusable.
- **Certs are free; idle certs cost nothing (18.4):** so placement is *not* a cost decision, purely a lifecycle/grouping one.

## What the Verify is really testing
No standalone Verify; correctness shows downstream (the ALB and CloudFront serve valid TLS in S20/S22). The conceptual point: **a cert's layer is chosen by its own longevity, not its consumer's** (cert A outlives the ALB that uses it). And GD4 (Session 7) teaches that deleting the validation record doesn't kill the cert instantly; certs *renew*.

## Cross-links
- Cert-A placement decision → `decisions/cert-placement.md`.
- Provider aliases (multi-region) → `concepts/terraform-layers-state.md`.

## Done when
Cert A lives in an always-on layer and is referenced by ARN from the ALB; cert B is created in us-east-1 via a provider alias; both validate automatically via Route 53.
