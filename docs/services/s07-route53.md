# S07: Route 53

**Layer:** 00-foundation (zone) · **Session:** 4 · **Concept:** `concepts/aws-mental-model.md`

## Purpose
Authoritative DNS for `aws.gmora.work`. The naming substrate: everything user-facing gets a stable name here, which is what makes teardown/rebuild transparent.

## Requirements that carry hidden depth
- **Zone in layer 00, never destroyed (7.1):** `$0.50/mo`, `prevent_destroy`. If the zone died on teardown you'd re-delegate every session.
- **Delegation = 4 NS records in Cloudflare (7.2):** the hop where DNS actually starts resolving: Cloudflare (parent of `gmora.work`) points `aws.gmora.work` at Route 53's NS set. TTL 3600. Miss this and the zone exists but nothing resolves.
- **Records created by *owning* layers (7.3):** `webhook` A-alias → API GW (layer 10, Session 4); `api` → ALB and `status` → CloudFront (layer 30, Session 5). **Alias records point at an AWS resource with no IP**, which is why they survive the layer being destroyed and rebuilt: everything references the *name*, never an address.
- **No wildcards (7.4):** each name explicit. A wildcard would mask typos and over-expose.

## What the Verify is really testing
**7.4, `dig +trace webhook.aws.gmora.work`, follow delegation hop by hop.** You do DNS-adjacent work; this makes AWS's side concrete. **Predict-before-test:** write the delegation chain (root → `.work` → Cloudflare → Route 53) before you trace it.

## Cross-links
- Alias records and the name-not-IP principle → `sessions/session-04.md`, `sessions/session-05.md`.

## Done when
Zone delegated and resolving; `dig +trace` follows the chain you predicted.
