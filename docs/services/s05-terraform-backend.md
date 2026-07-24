# S05: Terraform backend, repo & state layout

**Layer:** bootstrap + all · **Session:** 2-3 · **Concept:** `concepts/terraform-layers-state.md` · **Decision:** `decisions/state-wiring.md`

## Purpose
The foundation that makes every later layer buildable and every teardown boring: remote state, the layer split, cross-layer wiring, and the guardrails. Get this right once and the next 20 services are mechanical.

## Requirements that carry hidden depth
- **State bucket, versioned (5.1):** versioning ON is your **rollback seatbelt** (a bad apply → restore a prior state object). SSE-S3, BPA, 30 noncurrent versions.
- **Native lockfile, no DynamoDB table (5.2):** `use_lockfile=true` (needs TF ≥ 1.10). Know *both* patterns and why the DynamoDB lock table is now legacy; interview-grade.
- **State keys per layer (5.3):** `00-org` (management), `00-foundation`, `10-serverless`, `20-network`, `30-compute`. **Open question the spec leaves:** *which bucket* holds `00-org`'s state (management-account bucket vs cross-account); resolve it as an ADR (see `sessions/session-02.md`; my lean: a management-account bucket).
- **Bootstrap chicken-and-egg (5.4):** the state bucket is Terraform-managed but Terraform needs a backend: create with **local state first**, then `terraform init -migrate-state`. Document it (`docs/bootstrap.md`). Same class as a Flux/GitOps bootstrap.
- **Cross-layer wiring = SSM (5.6, [you decide]):** producers write to `/lf/dev/tf/<layer>/<name>`, consumers read via `data`. Chosen over `terraform_remote_state` (which exposes the *whole* state file). **The failure mode to know:** destroy layer 20 → its SSM params vanish → layer 30 can't even `plan`. That's correct, and it's why ordering is load-bearing. Full reasoning: `decisions/state-wiring.md`.
- **`prevent_destroy` guards (5.12):** on hosted zone, state bucket, audit bucket, ECR repos, DynamoDB table. This is what makes aggressive teardown *safe*: the irreversible things are pinned; a fat-finger destroy errors instead of deleting. One documented override for the DR drill.
- **`default_tags` from resource one (5.7):** retrofitting tags is painful and untagged spend can't be attributed. (And you must *activate* them as cost-allocation tags separately; `cost-and-teardown`.)
- **Two SSO profiles (5.11):** `lf-mgmt` (00-org only) and `lf-dev` (everything else). Each layer targets one account; no cross-account assumption yet.

## What the Verify is really testing
**Two concurrent `terraform apply` in one layer → the second fails on the lock.** It's the locking mechanism proving itself. **Predict-before-test** what the second run does and which artifact causes it. Also: **`just down && just up` completes hands-off**, the real measure of "your IaC is boring enough to trust."

## Cross-links
- The whole state/layer/wiring model → `concepts/terraform-layers-state.md`.
- The SSM-vs-remote_state decision → `decisions/state-wiring.md`.

## Done when
Remote state with native locking, the five layers scaffolded, SSM wiring pattern established, `prevent_destroy` + `default_tags` in place, both profiles working, and the lock + `down/up` Verifies pass.
