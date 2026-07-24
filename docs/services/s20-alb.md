# S20: ALB

**Layer:** 30-compute · **Session:** 5 · **Concept:** `concepts/networking-no-nat.md`, `concepts/cost-and-teardown.md`

## Purpose
The load balancer for the query API. **Internal**, not internet-facing: one of the key audit fixes.

## Requirements that carry hidden depth
- **`scheme = internal` (20.1):** the query API is staff-only (§1.4) and serves PII, so it **must not** sit on the public internet (the audit caught it as internet-facing + unauthenticated). You reach it via **SSM port-forward or a bastion**, not an open URL. Subnets are the *private* ones; SG `lf-alb-sg`.
- **Bills by the hour whether or not traffic flows:** this is why the ALB is in the torn-down layer 30 (`cost-and-teardown`). ~$0.80 over a weekend session if you forget teardown.
- **`target_type = ip` (20.4):** required for Fargate (tasks have ENIs, not instances). Health check `/healthz`, `deregistration_delay = 30` (drains connections before killing a task, the reason kill-one-task can be zero-5xx).
- **:80 redirects to :443; TLS13 policy (20.2/20.3):** no plaintext; cert A on the :443 listener.
- **DNS alias created in layer 30 (20.5):** `api.aws.gmora.work` **dies and returns with the layer**, so everything references the name, never the IP.

## What the Verify is really testing
The ALB's real proof comes with ECS in **S21.13**: kill one of two api tasks under load → **zero 5xx** at the ALB. That works *because* of health checks + `deregistration_delay` + desired=2 draining gracefully. **Predict** zero-5xx before the test.

## Cross-links
- Why internal + how to reach it → `sessions/session-05.md` (port-forward runbook).
- Hourly billing → teardown → `concepts/cost-and-teardown.md`.
- The ECS services behind it → `services/s21-ecs.md`.

## Done when
Internal ALB with :80→:443 redirect, TLS13, an `ip` target group with `/healthz` and drain delay; reachable only via port-forward/bastion; `api` alias in layer 30.
