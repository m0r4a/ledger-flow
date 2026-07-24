# Session 3: finish the Terraform backend, then passwordless CI (OIDC)

**Covers:** the rest of **S05** (repo layout, `justfile`, version pins, layer scaffolding) and all of **S06** (GitHub OIDC provider + two CI roles + two workflows). Theme: **make the repo and the deploy path production-shaped before there's anything real to deploy.** By the end, a PR runs `terraform plan` in CI with *no stored AWS secret*, and `main` can build/deploy, all authenticated by short-lived OIDC tokens.

> Re-read `concepts/identity-accounts-iam.md`, specifically the **trust-vs-permission split**, the **four policy types**, the **OIDC `sub`/`aud`** section, and `iam:PassRole`. Also `concepts/least-privilege.md`. S06 is the first place you *build* all of that, and the fork trap is the single most important idea in the session.

---

## The frame

Session 2 got the money guardrails, audit, and state backend standing. Session 3 finishes the plumbing so every later session is boring:

- **S05 tail** is unglamorous but load-bearing: the repo layout, `just` targets, and version pins are what make `just up`/`just down` and CI work for the next 20 services. Do it right once.
- **S06 is the security-sensitive one.** CI needs to touch AWS with **zero long-lived credentials** (G4). OIDC is how, and a single wildcard in the wrong place would let *any fork's PR* assume your deploy role. This session is where "passwordless CI" and "least privilege" stop being concepts and become two IAM roles you can defend line by line.

You're still in `mora-dev` for all of this (OIDC roles live in dev; CI only ever touches dev; see the two-account table in `identity-accounts-iam`).

---

## S05 tail: the plumbing that makes everything else boring

- **Repo layout (S05.8):** `infra/{00-foundation,10-serverless,20-network,30-compute}/`, `services/{ledger-api,fraud-worker}/`, `functions/{ingest,notify,archiver,canary,reconciler}/`, `loadgen/`, `docs/{runbooks,gamedays,adr}/`, `justfile`. Note this is the spec's layout; your current `justfile` only lints `./terraform` and `./go` (S01/D1), so reconcile it now (this was the "fix it when I reach 5.8" item). Also note `00-org` lives wherever you put the management layer (Session 2's ADR); it's not in the dev `infra/` tree if you kept accounts clean.
- **`justfile` targets (S05.9):** `up` (apply 20 then 30), `down` (destroy 30 then 20), `status` (list ALBs / ECS services / **NAT GWs → must print 0**), `cost` (infracost on changed dirs). *These don't fully exercise yet* (20/30 are empty until Session 5), but write them now so the muscle memory and the ordering are baked in. The ordering (`up` = 20→30, `down` = 30→20) is the SSM-wiring dependency from `terraform-layers-state`; get it right here so you never think about it again.
- **Version pins (S05.10):** `required_version` and the AWS provider pinned with `~>` in *every* layer; commit `.terraform.lock.hcl`. This is what stops a provider upgrade from silently changing a plan six weeks from now.
- **Cross-layer wiring (S05.6):** the SSM pattern is *established* now but not *exercised* until layers reference each other in Session 5. Read `decisions/state-wiring.md` now so the pattern is in your head; you don't write cross-layer `data` sources yet.

**Trap:** it's tempting to skip the `justfile`/layout polish because "there's nothing in 20/30 yet." Don't; retrofitting the ordering and targets after you've built the VPC is how you get a half-torn-down stack that won't `plan`.

---

## S06: OIDC and the two CI roles

### The mental model (read this before writing any HCL)
GitHub Actions mints a short-lived signed **JWT** per run; you register GitHub's **OIDC provider** in IAM as trusted (S06.1: issuer `token.actions.githubusercontent.com`, audience `sts.amazonaws.com`); each role's **trust policy** validates the token's claims and, if they match, STS hands the workflow temporary creds. No secret is ever stored. This is the `identity-accounts-iam` OIDC section made real.

### Two roles, two blast radii
- **`lf-gha-plan` (S06.2):** trust `sub = repo:m0r4a/<repo>:pull_request`; permissions: `ReadOnlyAccess` + `s3:GetObject/ListBucket` on the state bucket + `ssm:GetParameter` on `/lf/dev/tf/*`. **Plan-only, read-only**, because it runs on PRs, which fork contributors can open. It must not be able to *change* anything.
- **`lf-gha-deploy` (S06.3):** trust `sub = repo:m0r4a/<repo>:ref:refs/heads/main` **exactly**; permissions: ECR push to `lf/*`, `ecs:UpdateService/RegisterTaskDefinition/DescribeServices`, and `iam:PassRole` on **only** the two task/exec role ARNs **with** the `iam:PassedToService = ecs-tasks.amazonaws.com` condition. This one can deploy, so its trust is pinned to `main` and its permissions are surgical.

### The fork trap (the thing this session is really teaching)
If you wildcard the repo segment of `sub` (or use a loose `StringLike`), **any fork's pull request can assume your role**: a fork PR runs with a token whose `sub` you'd be matching too broadly. That's why deploy is pinned to `main` *exactly* and plan is scoped to `pull_request` with read-only perms. The Verify (S06.6) is: *a PR from a fork cannot assume either role*. Test it, or reason it through from the `sub` claim and **write the reasoning in an ADR**. This is a predict-before-test-adjacent exercise: state *why* the fork is blocked before you prove it.

### The `iam:PassRole` piece
The deploy role needs `iam:PassRole` so ECS can run tasks *as* the task roles, but scoped to exactly those two ARNs, with `PassedToService` locking it to ECS. Understand why (from `least-privilege`): without the condition, `PassRole` on a powerful role is an escalation primitive. You'll deny-by-default everything else.

### The workflows
- **`terraform-ci.yml` (S06.4):** on a PR touching `infra/**`: fmt-check, validate, tflint, `plan` per changed layer, plan posted as a PR comment. **No apply in CI**; apply is you, locally. That's the right maturity here: CI reviews, humans apply.
- **`build-deploy.yml` (S06.5):** on push to `main` touching `services/**`/`functions/**`: `go vet`, lint, test, build, push, deploy. It won't have anything to build until Session 4, but the skeleton lands now.
- **Zero repo secrets (S06.6):** the Actions secrets list is **empty**; role ARNs go in repo *variables* (ARNs aren't secret). If you ever feel the urge to paste an access key into a GitHub secret, stop; that's the exact thing OIDC exists to prevent.

---

## Predict-before-test targets (`my_log.md` first)

1. **S06.6 fork assumption.** *Predict:* will a fork PR be able to assume `lf-gha-plan`? `lf-gha-deploy`? State the `sub` value a fork PR presents and why each trust policy rejects it, before you test or reason it out formally.
2. **First CI plan.** *Predict:* when you open a PR touching `infra/**`, which layers will `terraform-ci.yml` plan, and will the plan role's read-only permissions be *enough* to plan (or will a missing read permission surface as an error)? A too-tight plan role failing to `plan` is a common first-run surprise.

*(S05 tail is mostly config/boolean, no predictions needed there beyond the lock test you already did in Session 2.)*

---

## Verify checklist

- [ ] **S05.8/5.9:** repo matches the spec layout; `just status` runs and prints `NAT gateways: 0`; `just up`/`down` exist with correct ordering (even if 20/30 are empty).
- [ ] **S05.10:** every layer pins `required_version` + provider `~>`; `.terraform.lock.hcl` committed.
- [ ] **S06.6 (the big one):** a fork PR **cannot** assume either role; reasoning written in an ADR.
- [ ] **S06.4:** a PR touching `infra/**` triggers plan-in-CI, posted as a comment, using OIDC (no stored secret).
- [ ] **S06.6:** GitHub Actions **secrets list is empty**; only repo *variables* hold role ARNs.
- [ ] Both roles' trust policies pin `sub` (deploy = `main` exactly, plan = `pull_request`); deploy's `iam:PassRole` is scoped to the two task-role ARNs with `PassedToService`.

## Artifacts to leave behind

- **ADR: the fork-trap reasoning:** the `sub` claim values, why each role rejects a fork PR, and the `aud` check. This is a portfolio-grade ADR; write it in your own words.
- **`my_log.md`:** `S06 6.6` with your prediction and the result.

## Definition of done

Repo is spec-shaped with working `just` targets and pinned versions; the OIDC provider and both CI roles exist with correctly-scoped trust and permissions; a PR plans in CI over OIDC; the fork trap is proven-or-reasoned and ADR'd; zero secrets in the repo.

---

## Next

Session 4 (spec's "Session 4-6") is the big one: **S07-S14**, ending in your **first end-to-end event flow**: a signed webhook travels API GW → ingest Lambda → SNS → SQS fan-out → archiver/notify, all serverless, all ≈free, all staying up 24/7. Read `concepts/messaging-fanout.md` and `concepts/dynamodb-single-table.md` before it. Brief: `sessions/session-04.md`.
