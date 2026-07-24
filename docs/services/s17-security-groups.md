# S17: Security groups

**Layer:** 20-network · **Session:** 5 · **Concept:** `concepts/networking-no-nat.md`

## Purpose
Who may talk to whom: stateful interface ACLs forming a tight chain from the ALB down to the endpoints.

## Requirements that carry hidden depth
- **SG references, never CIDRs, for internal hops (17):** the chain is `lf-alb-sg` (443 from within VPC) → `lf-api-sg` (8080 **from lf-alb-sg**) → `lf-vpce-sg` (443 **from api/worker sg**). Sources are *other security groups*, an **identity** match that classic ACLs lack (`networking-no-nat`). More precise and survives IP changes.
- **Internal ALB SG, no `0.0.0.0/0` (17, `lf-alb-sg`):** inbound 443 from within the VPC / a bastion SG only. The audit fix: the query API is staff-only, not internet-facing.
- **Zero `0.0.0.0/0` egress anywhere in 20/30 (17.1):** the deliberate lockdown that turns every "it can't connect" into a security-group lesson instead of silently working. This is a *feature*.
- **Every rule has a description (17.2):** self-documenting; also forces you to articulate *why* each hole exists.

## What the Verify is really testing
**17.3, `describe-security-groups` filtered by `tag:project=ledgerflow`, piped through jq, shows no `0.0.0.0/0` egress.** It proves the closed-egress posture held across every SG. Any open egress means something wanted the internet; go ask *why* before allowing it.

## Cross-links
- Stateful SGs, SG-references, the closed-egress rationale → `concepts/networking-no-nat.md`.

## Done when
The SG chain is wired by reference (not CIDR), the ALB SG has no public ingress, and the jq check finds zero open egress in 20/30.
