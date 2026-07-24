# S26: IAM hardening pass

**Layer:** cross-cutting · **Session:** 7 · **Concept:** `concepts/least-privilege.md`, `concepts/identity-accounts-iam.md`

## Purpose
After everything works, tighten and *prove* least privilege: audit against reality, run the analyzers, and demonstrate a permission boundary actually caps escalation.

## Requirements that carry hidden depth
- **26.5 first: read the policy-evaluation doc, start to finish, 30 min. Non-negotiable.** Everything else assumes you can trace an `Allow` through `SCP ∩ boundary ∩ identity`. Do it *before* 26.4.
- **Inventory from the *live account*, not Terraform (26.1):** `docs/iam.md`: every role, its trust policy, permissions, one sentence of why, read from the console/CLI to **find the drift**. Reading your Terraform would hide the exact drift you're hunting.
- **Access Analyzer policy validation → zero findings (26.2):** on every customer-managed policy; catches over-broad grants you can't eyeball.
- **Access Analyzer external-access → zero findings (26.3):** the design expects *none*, so any finding is a real leak.
- **The permission-boundary exercise (26.4), the staff-level proof:** attach `lf-deploy-boundary` (ECR/ECS/logs only) to `lf-gha-deploy`, add `iam:CreateUser` to its identity policy, and **prove via CLI that creation still fails** (effective perms = identity ∩ boundary). Revert. **ADR-004 in your own words**; this proves you *understand* the evaluation model, not just configured it.

## What the Verify is really testing
26.4 is the centerpiece: it proves a boundary is a genuine ceiling, not advisory: the mechanism a platform team uses to let others create roles without letting them escalate. **Predict-before-test:** the exact error and *which layer* denies it (the boundary, not the identity policy). Predict for 26.1 whether you'll find any drift.

## Cross-links
- Boundaries, the scope-from-access-patterns method, Access Analyzer → `concepts/least-privilege.md`.
- Policy evaluation order → `concepts/identity-accounts-iam.md`.

## Done when
Policy-eval doc read; live-account IAM inventory written (drift found or confirmed none); analyzers clean; the boundary proven with CreateUser failing; ADR-004 written.
