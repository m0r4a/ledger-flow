# S01: Local tooling

**Layer:** local · **Session:** 1 · **Concept:** (none)

## Purpose
The toolchain everything else assumes. Mostly boolean checks, but two versions carry hidden weight.

## Requirements that carry hidden depth
- **Terraform ≥ 1.10 (1.2):** *not* arbitrary. 1.10 added the **native S3 lockfile** (`use_lockfile=true`), which is why the spec skips the legacy DynamoDB lock table (S05.2). An older Terraform would force you back onto the DynamoDB pattern. See `concepts/terraform-layers-state.md`.
- **Docker buildx, arm64 (1.5):** you build **`linux/arm64`** images because Fargate/Lambda run arm64 here (cheaper, and the spec's images target it, S13.1/S19.4). If your workstation is x86, buildx cross-builds; confirm the arm64 builder exists *now*, not when a push fails in Session 5.
- **`just check` / pre-commit (1.6):** `terraform fmt -check`, `tflint`, `golangci-lint run`. Note your current `justfile` lints `./terraform`/`./go`, which drifts from the spec's `infra/`/`services/`/`functions/` layout; you reconcile that in S05.8 (Session 3).

## What the Verify is really testing
`aws --version` 2.x, `terraform version` ≥ 1.10, `docker buildx ls` shows arm64. Those are the two facts that would otherwise fail *silently and late*: a too-old Terraform (backend breaks) and a missing arm64 builder (image push breaks). Trivial/boolean → no prediction needed.

## Done when
All versions check out and buildx can target arm64.
