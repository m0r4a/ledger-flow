# Session 5: the locked-down VPC, containers, and the edge (S15-S22)

**Covers:** the spec's "Session 7-10" block: **S15** VPC, **S16** VPC endpoints, **S17** security groups, **S18** ACM, **S19** ECR, **S20** internal ALB, **S21** ECS (including `fraud-worker`, which finally completes the ledger write path), **S22** CloudFront. This is the hardest block in the project, and **the network is designed to fail loudly**: the debugging *is* the deliverable. Everything here is **layers 20 (network) and 30 (compute)**, the session-only, hourly-billed side that `just down` destroys.

> Read `concepts/networking-no-nat.md` before touching anything; it's the whole mental model for why things will hang. Then have four dossiers open as you hit them: `image-base` (S19), `worker-capacity` (S21.8), `cloudfront-layer` (S22.3), and `tracing` (S24.4; the ADOT sidecar decision is set up on the ECS services here even though tracing gets polished in Session 6).

---

## The frame

Sessions 2-4 lived in the always-on serverless world where the network "just worked" (no-VPC Lambdas). Session 5 is the opposite: you **build the network by hand, with no NAT and zero open egress**, and then run containers inside it that can only reach AWS through **exact VPC endpoints**. Expect hangs. A hang here is not a bug to be frustrated by; it's the scripted lesson (missing endpoint, wrong SG, private DNS off). This is also the session where the **hourly billing** starts, so the teardown reflex (`just down`, verify zero) begins in earnest.

Two milestones land here: the **container image pipeline works end-to-end through private endpoints** (S16.3, the flagship debugging exercise), and **`fraud-worker` completes the ledger write path**: the DynamoDB writes that Session 4 set up but couldn't finish.

---

## The arc (and why the order is forced)

The network must exist before anything runs in it, and the layer split (20 then 30) mirrors that:

1. **Layer 20 (S15 VPC → S16 endpoints → S17 SGs).** The address plan and routing, then the *only* way out (endpoints), then who-may-talk-to-whom (SGs). Nothing runs yet; you're building the room before the furniture.
2. **S18 ACM + S19 ECR:** cert B (us-east-1, the multi-provider-alias exercise) and the image registry. (Cert A you may already have from Session 4; see `decisions/cert-placement.md`.)
3. **Layer 30 (S20 ALB → S21 ECS → S22 CloudFront).** The internal load balancer, the two services (api + worker), and the edge for the status page.

**The SSM cross-layer wiring finally gets exercised here** (`decisions/state-wiring.md`): layer 20 publishes VPC/subnet/SG IDs to `/lf/dev/tf/20-network/*`; layer 30 reads them. This is where the ordering (`up` = 20→30, `down` = 30→20) stops being theoretical: destroy 20 and 30 can't even `plan`.

---

## Per-service traps and the "why"

### S15 VPC (Cisco model; see `networking-no-nat`)
- `10.20.0.0/16`, **DNS support + DNS hostnames both on** (S15.1): the endpoints' private DNS needs both; forget this and SDK calls resolve the *public* endpoint and hang.
- Four subnets, two AZs. **Private route tables have NO default route** (S15.4): a router with no `ip route 0.0.0.0/0`. No NAT, ever. The Verify (S15.6): a private RT shows *exactly* `local` + the two gateway-endpoint prefix-list routes after S16, nothing else.
- Flow logs **off** (cost), with a commented block ready for a game day.

### S16 VPC endpoints: the flagship debugging exercise
- **Gateway (free): S3, DynamoDB** are route-table entries. **Interface (~$0.01/h each): ecr.api, ecr.dkr, logs, sqs, ssmmessages, ssm** are ENIs with `private_dns_enabled=true`, SG `lf-vpce-sg`. Six interface endpoints ≈ the layer's main hourly cost, which is why they die with `just down`.
- **S16.3 (the core deliverable):** a Fargate task in private-a pulls an image from ECR, and you must explain **which of ecr.api / ecr.dkr / s3-gateway served which part** (control-plane auth; registry/manifest protocol; the layer *blobs* live in S3, the one people forget). If the pull hangs, exactly one endpoint is missing/misconfigured. **Write this up**; it's explicitly a core deliverable. Predict-before-test: predict which endpoint each pull stage uses *before* you launch the task.
- **S16.4 (negative Verify):** ECS Exec into the task, `curl -m 5 https://checkip.amazonaws.com` → **must fail**. Proving there's no internet path is an acceptance test, not a problem.

### S17 security groups (stateful interface ACLs)
- The chain: **`lf-alb-sg` (443 from within VPC, internal, no `0.0.0.0/0`) → `lf-api-sg` (8080 from alb-sg) → `lf-vpce-sg` (443 from api/worker sg)**. Sources are **SG references, never CIDRs** (the identity-match that classic ACLs lack; `networking-no-nat`).
- **Zero `0.0.0.0/0` egress anywhere in 20/30** (S17.1): the deliberate lockdown. Every rule has a `description` (S17.2). Verify S17.3: `describe-security-groups` filtered by tag, piped through jq, shows no open egress.

### S18 ACM (multi-region)
- **Cert A** (us-east-2) may already exist from Session 4 (`decisions/cert-placement.md`). **Cert B** (us-east-1, layer 30, **provider alias**) for CloudFront is the multi-provider-alias Terraform exercise (`terraform-layers-state` → provider aliases). DNS validation fully automated: `aws_acm_certificate` → `aws_route53_record` (`for_each` over `domain_validation_options`) → `aws_acm_certificate_validation`.

### S19 ECR
- `IMMUTABLE` tags, scan-on-push, images tagged **full 40-char git SHA only, no `latest`, ever** (S19.3). Repos in layer 00 (images survive `just down`). Multi-stage build → `distroless/static` or `scratch` (`decisions/image-base.md`), `USER nonroot`, arm64, **< 25 MB**, zero CRITICAL scan findings.

### S20 internal ALB
- **`scheme = internal`** (S20.1): the query API is staff-only (§1.4), *must not* face the public internet. Reach it via **SSM port-forward or a bastion**, not an open URL. This is the audit fix (was internet-facing + unauthenticated serving PII). `drop_invalid_header_fields=true`, TLS13 policy, :80 redirects to :443.
- Target group `target_type=ip` (Fargate requirement), health check `/healthz`. `api.aws.gmora.work` A-alias created in layer 30, which **dies and returns with the layer**, so everything references the *name*, never IPs.

### S21 ECS: where the ledger write path completes
- Cluster `lf-dev`, **Fargate + Fargate Spot** capacity providers, **Container Insights OFF** (bills per metric).
- **Roles are the least-privilege showcase:** shared exec role `lf-task-exec` (pulls images + injects secrets *before your code runs*, so understand that timing); task role `lf-ledger-api-task` (`dynamodb:GetItem,Query` on table+GSIs, `ssmmessages` for Exec, xray, nothing else); task role `lf-fraud-worker-task` (`dynamodb:PutItem/GetItem/Query/UpdateItem`, `sqs` consume on `lf-fraud-q` **only**, xray). This is the S24.5 setup: revoking the worker's `PutItem` later is the observability capstone.
- **`fraud-worker` (S21.11)** completes the write path: long-poll fraud-q → drop `synthetic=true` → **conditional-put idempotency** → score (amount > 500 000 cents → +40; > 3 events/customer/60s → +30; ≥ 50 → FLAGGED) → write TXN → delete. SIGTERM graceful drain < 25s. **Velocity scoring is best-effort under concurrency** (documented, not fixed; idempotency stays exact). Capacity is your `worker-capacity` ADR (Fargate vs Spot).
- **`ledger-api` (S21.10)** serves the query APIs (AP1/AP2/AP3), `/healthz` + `/readyz`, Mat Ryer pattern, graceful shutdown.
- **Autoscaling on backlog-per-task** (S21.9): `ApproximateNumberOfMessagesVisible / RunningTaskCount`, target 30, 1→3 tasks.
- **Deployment circuit breaker on with rollback** (S21.7): a bad deploy auto-rolls-back; CI fails the job if it triggers (S21.12).

### S22 CloudFront
- OAC (not legacy OAI), `PriceClass_100`, cert B, alias `status.aws.gmora.work`. Bucket policy allows `GetObject` only to the distribution via OAC `SourceArn`. **Layer decision:** `decisions/cloudfront-layer.md` (30 vs 10: the ~5-min create/delete latency vs teardown-cleanliness tradeoff).

---

## Predict-before-test targets (`my_log.md` first, several behavioral ones here)

1. **S16.3:** which endpoint (ecr.api / ecr.dkr / s3-gateway) serves which stage of the ECR pull. Predict, then pull.
2. **S16.4:** the `curl` from inside the task fails (no internet). Predict the failure mode (hang to timeout vs immediate).
3. **S21.13 kill-one-task-under-load:** predict: does the ALB serve **zero 5xx** while one of two api tasks dies? (Deregistration delay, health checks, desired=2.)
4. **S21.13 500-message flood:** predict the **drain time** using **Little's Law** *before* the test (S27/GD2 previews this): backlog ÷ (workers × throughput). Then scale 1→3, drain, return to 1, and compare.
5. **S22.4:** direct bucket URL → 403, `https://status.aws.gmora.work` → 200 with an `x-cache` header. Predict both.

---

## Verify checklist

- [ ] **S15.6:** `just status` prints `NAT gateways: 0`; private RT has only local + 2 gateway-endpoint routes.
- [ ] **S16.3:** Fargate task pulls from ECR through the private endpoints; you can explain which endpoint served which part (written up).
- [ ] **S16.4:** `curl` from inside the task **fails** (no internet path).
- [ ] **S17.3:** no `0.0.0.0/0` egress anywhere in 20/30 (jq check).
- [ ] **S19.5:** image non-root numeric UID, < 25 MB, zero CRITICAL scan findings; no `latest` tag anywhere.
- [ ] **S21.13:** kill-one-task → zero 5xx; 500-msg flood → scales to 3, drains, returns to 1; drain time compared to your Little's-Law prediction.
- [ ] **S10.6 (now completable):** replay one webhook 50× → exactly 1 TXN + 1 IDEM item; 49 handled `ConditionalCheckFailedException`.
- [ ] **S22.4:** bucket 403, CloudFront 200 with `x-cache`.
- [ ] **Teardown:** `just down && just up` completes hands-off; `just status` shows zero after down.

## Artifacts to leave behind

- **The S16.3 write-up** (which endpoint served which part of the pull): this is portfolio-grade; it's the single most "SRE" artifact in the project so far.
- **ADRs:** image-base (S19.4), worker-capacity (S21.8), cloudfront-layer (S22.3), and the cert-B multi-region note if not already covered.
- **`my_log.md`:** the five predictions above with actuals; the drain-time arithmetic especially.
- **`docs/runbooks/`:** how to reach the internal ALB (SSM port-forward steps).

## Definition of done

The VPC exists with no NAT and no open egress; containers pull and run through exact endpoints (and you can explain the pull); the SG chain is SG-referenced and closed; both ECS services run, `fraud-worker` completes the ledger write path with exact idempotency, autoscaling and circuit-breaker work; the internal ALB serves the query API (reachable only via port-forward/bastion); CloudFront serves the status page. And critically: **`just down` tears the hourly half down cleanly and `just up` rebuilds it boring.**

---

## Next

Session 6 (spec's "Session 11-13") wires the **remaining Lambdas + scheduling + full observability**: **S13-rest** (notify, canary, reconciler), **S23** EventBridge Scheduler, **S24** CloudWatch (EMF metrics, burn-rate alarms, SLOs, the dashboard, tracing). Read `concepts/observability-slo.md` first. Brief: `sessions/session-06.md`.
