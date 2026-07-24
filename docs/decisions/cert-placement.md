# Decision: where cert A lives (00-foundation vs 10-serverless)

**Spec ref:** S18.1, S18.4 · **ADR:** ADR-003 · **Constraint fixed by spec:** NOT layer 20.

## The decision

Cert A (us-east-2, CN `api.aws.gmora.work`, SAN `webhook.aws.gmora.work`) is used by **two** things with different lifecycles: the **ALB** in layer 30 (session-only) and the **API Gateway custom domain** in layer 10 (always-on, 24/7). Where does the certificate resource itself live?

## The hard constraint

It **cannot** live in layer 20 (or 30). Tearing down 20/30 each session would destroy the cert, and the webhook custom domain in layer 10 needs it 24/7, so killing it would take down the always-on ingress every session (this violates **G3 teardown discipline**, since the always-on half must survive `just down`). So the cert must live in an always-on layer. The ALB references it by ARN via SSM (S05.6), so the ALB being in layer 30 is fine; it just reads the ARN.

That narrows the real choice to **two always-on homes: 00-foundation or 10-serverless.**

## Options

| Option | For | Against |
|---|---|---|
| **00-foundation** | Certs are foundational, long-lived, shared infra, on the same shelf as the hosted zone, ECR, OIDC. Groups "things that outlive everything and rarely change." | Slightly further from the API Gateway that's its most always-on consumer |
| **10-serverless** | Co-located with the API GW custom domain that consumes it 24/7; the serverless layer "owns" the always-on ingress end to end | Mixes a foundational primitive into the app layer; if you ever rebuilt 10 from scratch you'd churn the cert (and DNS validation) too |

## What barely moves the needle

ACM certs are **free** and idle certs cost nothing (S18.4), so this is *not* a cost decision. It's purely about which layer's lifecycle and mental model the cert belongs to. Both candidate layers are always-on, so neither risks the teardown problem.

## My lean

**00-foundation.** A TLS cert for your stable domain is foundational infrastructure with hosted-zone-like longevity; it belongs with the other never-destroyed primitives, and keeping it out of the app layer means rebuilding 10 doesn't churn certificate DNS validation. The defensible counter: if you think of the whole webhook ingress (API GW + domain + cert) as one cohesive unit, 10 keeps that unit together. Either is correct; pick the grouping principle you believe and state it.

## Interview angle

"You have a resource shared by a permanent component and an ephemeral one, so where does it live?" The reasoning (put shared long-lived resources in the layer whose lifecycle matches *their* longevity, not their consumer's; reference across boundaries by ARN) is the transferable lesson.

## Write ADR-003

Record: the layer-20 exclusion and *why* (G3), the two always-on candidates, your choice and the grouping principle behind it, and the ARN-via-SSM reference from the ALB.

## Primary sources

- ACM User Guide (DNS validation with `aws_acm_certificate_validation`, `for_each` over `domain_validation_options`; S18.3).
- Cross-layer references: `decisions/state-wiring.md`.
