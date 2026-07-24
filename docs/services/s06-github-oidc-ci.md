# S06: GitHub OIDC & CI

**Layer:** 00-foundation · **Session:** 3 · **Concept:** `concepts/identity-accounts-iam.md` (OIDC), `concepts/least-privilege.md`

## Purpose
Passwordless CI: GitHub Actions deploys to AWS holding **zero** stored credentials (G4). This is where OIDC, the fork trap, and `iam:PassRole` scoping stop being concepts and become two roles you can defend line by line.

## Requirements that carry hidden depth
- **OIDC provider (6.1):** issuer `token.actions.githubusercontent.com`, audience `sts.amazonaws.com`. GitHub mints a short-lived signed JWT per run; AWS trusts the provider; the trust policy validates claims. No secret stored.
- **Two roles, two blast radii:**
  - **`lf-gha-plan` (6.2):** trust `sub = repo:m0r4a/<repo>:pull_request`; **read-only** (`ReadOnlyAccess` + state read + `ssm:GetParameter` on `/lf/dev/tf/*`). It runs on PRs (fork-openable), so it must not be able to *change* anything.
  - **`lf-gha-deploy` (6.3):** trust `sub = repo:m0r4a/<repo>:ref:refs/heads/main` **exactly**; ECR push + `ecs:UpdateService/RegisterTaskDefinition/DescribeServices` + `iam:PassRole` on **only** the two task/exec roles with `iam:PassedToService=ecs-tasks.amazonaws.com`.
- **The fork trap (6.3), the single most important idea here:** a wildcard in the repo segment of `sub` (or a loose `StringLike`) lets **any fork's PR** assume your role. Deploy is pinned to `main` exactly; plan is `pull_request` + read-only. See `concepts/identity-accounts-iam.md` → OIDC.
- **`iam:PassRole` scoping (6.3):** deploy needs it so ECS runs tasks *as* the task roles, but scoped to exactly those ARNs + `PassedToService`. Unscoped `PassRole` on a powerful role is an escalation primitive (`least-privilege`).
- **No apply in CI (6.4):** CI plans on PRs and posts the plan as a comment; **you apply locally**. The right maturity: CI reviews, humans apply.
- **Zero repo secrets (6.6):** the Actions secrets list is empty; role ARNs go in repo **variables** (ARNs aren't secret). The urge to paste an access key is the exact thing OIDC removes.

## What the Verify is really testing
**6.6, a PR from a fork cannot assume either role.** It's testing your grasp of the `sub`/`aud` claims, not AWS. **Predict/reason first:** state the `sub` a fork PR presents and why each trust policy rejects it, then test or write the reasoning in an ADR. This ADR is portfolio-grade.

## Cross-links
- OIDC, `sub`/`aud`, the fork trap → `concepts/identity-accounts-iam.md`.
- `PassRole` and CI-role least privilege → `concepts/least-privilege.md`.
- Session arc → `sessions/session-03.md`.

## Done when
OIDC provider + both correctly-scoped roles exist; PRs plan in CI over OIDC; the fork trap is proven-or-reasoned and ADR'd; zero secrets in the repo.
