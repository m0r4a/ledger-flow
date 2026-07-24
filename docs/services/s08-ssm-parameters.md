# S08: SSM Parameter Store

**Layer:** 10-serverless (+ the `/tf/` bus written by all) · **Session:** 4 · **Concept:** `concepts/terraform-layers-state.md` (secrets-in-state), `concepts/least-privilege.md`

## Purpose
Three jobs in one tree: the HMAC secret, per-service config, and the cross-layer wiring bus.

## Requirements that carry hidden depth
- **The HMAC secret is generated locally and put by CLI, *never* in Terraform (8.2):** secrets in Terraform state = **plaintext in S3** (state stores every attribute in the clear; see `terraform-layers-state`). `openssl rand -hex 32` → `aws ssm put-parameter` as a **SecureString** (default KMS key). Services read it at runtime and cache it; Terraform references it as a data source only where unavoidable. This is the G4/G5 secret-handling discipline in its most concrete form.
- **The `/lf/dev/tf/<layer>/<output>` subtree is the wiring bus (8.1):** String type, written by Terraform, read by consumer layers. This is the mechanism behind `decisions/state-wiring.md`.
- **Standard tier only (8.3):** advanced-tier parameters *bill*; standard is free up to 10k. Don't reach for advanced tier for a project this size.
- **Rotation runbook (8.4):** `docs/runbooks/rotate-hmac.md`, ≤ 10 lines: put new value → restart consumers → verify old signature rejected. Rotating a live secret is "hard to reverse," so the runbook exists so you don't improvise it.

## What the Verify is really testing
No standalone behavioral Verify; the secret's correctness is proven downstream (ingest rejects a bad signature in S13.7/S14.6). The implicit check: **is the secret absent from `terraform state pull`?** If you can `grep` the secret out of state, you did it wrong.

## Cross-links
- Why secrets never live in state → `concepts/terraform-layers-state.md`.
- The scoped `ssm:GetParameter` grants per function → `concepts/least-privilege.md`, `services/s13-lambdas.md`.

## Done when
HMAC secret is a SecureString created out-of-band (not in state), the config + `/tf/` trees exist, and the rotation runbook is written.
