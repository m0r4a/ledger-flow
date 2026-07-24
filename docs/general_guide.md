# LedgerFlow: the general guide (start here)

This is the orientation map for the whole project: what LedgerFlow is, what every file and folder is *for*, how the pieces fit, and how to sit down and work a session. Read this once, then work just-in-time from the per-session and per-service pages.

---

## 1. What this project actually is

LedgerFlow is a fictional small-fintech platform (webhook ingest, async fan-out, a ledger, a query API, a status page, full observability), built entirely on AWS with Terraform and Go.

**But the product is not the point. The point is you learning AWS from near-zero by doing hard things with guidance.** Every design choice is a teacher. The difficulty is deliberate and comes from *AWS specifics*, not from hand-holding being withheld. You have as much explanation as you want (this whole `docs/` tree), while the building, debugging, and decisions stay genuinely yours.

If you internalize one framing: **AWS is a few hundred IAM-fronted API services in a region, not machines you log into.** Almost every problem is "was this API call authorized, was there a network path, did I shape it right." That reframing is in `concepts/aws-mental-model.md` and it unlocks the rest.

---

## 2. The architecture in one screen

**Two ingress paths, split by how they bill.** This is the split most of the design follows:

- **Serverless ingest (always-on, ≈ cents/month, stays up 24/7):**
  `webhook → API Gateway → ingest Lambda → SNS → SQS fan-out → { fraud-worker, notify, archiver }`, with a DynamoDB ledger, an S3 archive, and DynamoDB idempotency.
- **Container query path (session-only, bills hourly, torn down each session):**
  `internal ALB → ECS Fargate (ledger-api) + fraud-worker`, inside a locked-down VPC with **no NAT and zero open egress**. Everything reaches AWS through exact VPC endpoints.

**Accounts:** an AWS Organization with `mora-management` (billing, budgets, org CloudTrail, Identity Center) and `mora-dev` (all workload). You sign in with SSO profiles `lf-mgmt` and `lf-dev`.

**Region:** `us-east-2` everywhere, except the CloudFront cert and the billing metric/alarm (`us-east-1`, an AWS requirement).

**Terraform layers** (each an independent state, split by lifecycle):
`00-org` (management) · `00-foundation` (dev, forever) · `10-serverless` (dev, always-on) · `20-network` + `30-compute` (dev, **destroyed every session** by `just down`).

---

## 3. The map: what every file and folder is for

### The canon
- **`ledgerflow-complete.md`** is the spec (the "what"): 27 services (S01-S27), each with terse, parameter-level requirements and **Verify** gates, plus the cost model, build order, and game days. This is canon; build strictly in its order.

### The wiki you're reading (`docs/`, the "why")
- **`docs/README.md`** is the index and completeness map.
- **`docs/general_guide.md`** is this file.
- **`docs/concepts/`** (9) holds the cross-cutting *why*, tradeoffs, and failure modes. Read a concept page *before* the session that needs it:
  - `aws-mental-model` · `identity-accounts-iam` · `least-privilege` · `terraform-layers-state` · `cost-and-teardown` · `networking-no-nat` · `messaging-fanout` · `dynamodb-single-table` · `observability-slo`.
- **`docs/decisions/`** (8) has one dossier per `[you decide]` item: options, tradeoffs, failure modes, an *interview angle*, and my **lean**. You reach the conclusion and write the ADR. Covers: `state-wiring`, `cert-placement`, `image-base`, `worker-capacity`, `cloudfront-layer`, `canary-schedule`, `tracing`, `ingest-concurrency`.
- **`docs/sessions/`** (6) covers `session-02` through `session-07`, one per build-arc chunk. Each gives the **arc**, the cross-cutting **traps**, the **predict-before-test targets**, a **Verify checklist**, and a definition of done. Open the matching brief when you sit down to work.
- **`docs/services/`** (27) is a build-time reference per service, `s01` through `s27`: its purpose, the 2 to 4 requirements that carry hidden depth, **what each Verify is really testing**, and cross-links. Open the one you're building.

### Your working files (you own these)
- **`docs/adr/`** holds your Architecture Decision Records. Every `[you decide]` gets one; the dossier gives you the menu, the ADR records *your* choice and reasoning.
- **`docs/runbooks/`** holds your operational procedures (rotate-hmac, backlog-growing, dr-drill, how to reach the internal ALB). I review them.
- **`docs/gamedays/`** holds your five game-day write-ups (S27). These, the runbooks, and the design doc *are your portfolio*.
- **`docs/bootstrap.md`** lists the sanctioned non-IaC steps (Identity Center, the billing-alert preference, the state-bucket local-to-remote migration), documented so the account is reproducible by instructions.
- **`docs/slos.md`** is your SLO doc with the hand-computed error budget (S24.3).
- **`my_log.md`** is your session log and, importantly, your **predictions** (see the workflow below). Numbered `S<service> <req#>`.

### My operating files (private, gitignored)
- **`CLAUDE.md`** is my operating contract: my role, the difficulty knobs, the ground rules. Not project docs.
- **`.claude-faults.md`** is the ledger of any faults I seed on request, so nothing stays broken by accident.

---

## 4. How the guidance works: the four knobs

The difficulty is tuned by four switches you chose (all recorded in `CLAUDE.md`):

1. **Natural difficulty (ON).** The design is the teacher: no NAT, zero `0.0.0.0/0` egress, exact VPC endpoints, cross-layer SSM wiring. These are *designed to fail loudly* so each failure is a lesson. I don't soften them.
2. **Seeded faults on request (ON).** Say **"break something"** and I introduce **one** realistic misconfiguration, tell you nothing, and you debug from symptoms (CloudWatch, CloudTrail, flow logs). I log every seeded fault privately so nothing stays broken. **I never seed a fault unprompted.**
3. **Tiered hints (ON).** When you're stuck, my first response is the *next question* (which layer? what's the request path? what would you check first?), not the answer. I escalate only as you push, and give a direct answer only when you explicitly ask.
4. **Predict-before-you-test (ON, scoped).** Before any Verify with a **behavioral** outcome (latency, alarm-fire time, drain time, status codes) and before every game day, you write the expected result in `my_log.md` *first*, then compare. I enforce it: if you run a behavioral Verify without a written prediction, I'll ask for the prediction first. Trivial checks (version numbers, boolean flags) are exempt.

**My role** (fixed): I'm your requirements author, tradeoff-menu writer, failure-mode explainer, and reviewer. **I do not write your Terraform or Go.** I review against the Verify line and tell you what's wrong and where to look, without pasting the fix. I only write code when you explicitly ask *after a genuine attempt of your own*.

---

## 5. The ground rules (non-negotiable)

- **G1 IaC only.** The console is for reading; anything clicked gets recreated in Terraform before the phase counts. Bootstrap (Identity Center, account prefs) is the one documented exception.
- **G2 Budget.** $30/mo hard ceiling, $15 target, two-mechanism billing alert.
- **G3 Teardown discipline.** `just down` destroys the expensive layers every session; serverless stays up (cents). Rebuild must be boring.
- **G4 No long-lived credentials.** Everything is a role plus temporary STS creds; CI uses GitHub OIDC. No access keys anywhere.
- **G5 Least privilege from day one.** **G6 us-east-2.** **G7 everything tagged** (`project`, `layer`, `managed-by`).

---

## 6. The build order at a glance

| Chunk | Services | You'll have | Brief |
|---|---|---|---|
| Session 1 | S01-S02 | toolchain, secured roots, SSO | (done) |
| Session 2 | S03-S04, start S05 | billing guardrails, org audit, first Terraform | `sessions/session-02.md` |
| Session 3 | S05-rest, S06 | remote state + passwordless CI | `sessions/session-03.md` |
| Session 4 | S07-S14 | **first end-to-end serverless flow**, ≈ free, always-on | `sessions/session-04.md` |
| Session 5 | S15-S22 | locked-down VPC, containers, edge; ledger write path completes | `sessions/session-05.md` |
| Session 6 | S13-rest, S23-S24 | full observability, SLOs, tracing | `sessions/session-06.md` |
| Session 7 | S26-S27 | **the final exam**: IAM hardening, game days, DR drill | `sessions/session-07.md` |

---

## 7. How to work a session (the loop)

1. **Open the session brief** (`sessions/session-0N.md`) and get the arc, the traps, and the decisions in play.
2. **Read the concept page(s)** it points to, the *why* before you build.
3. **For each service, open its `services/sNN-*.md`** for the hidden-depth requirements and what the Verify really checks.
4. **Hit a `[you decide]`?** Read the dossier (`decisions/*.md`), choose, and write the ADR (`docs/adr/`).
5. **Before a behavioral Verify or a game day**, write your prediction in `my_log.md`.
6. **Build it** (your Terraform/Go). Stuck? Ask me, and you'll get the next question first, an answer only if you ask.
7. **Run the Verify**, compare to your prediction, log the result and any surprise (surprises are the highest-value log lines, because that's a mental model getting corrected).
8. **Tear down** the hourly layers (`just down`), glance at `just status` for zeros, and stop.

Want me to **review** something? Point me at it and the Verify line. Want to **debug a real fault**? Say "break something."

---

## 8. Where you are right now

- **Progress:** S01 done, mid-**S02** (Session 2).
- **Your next concrete move:** the `lf-mgmt` SSO profile and `sessions/session-02.md`.
- **Two open items you owe before building the org layer:** (1) the **management account ID**; (2) your **ADR decision on where `00-org`'s Terraform state lives** (the dossier-style writeup is in `sessions/session-02.md` and `services/s05-terraform-backend.md`; my lean is a management-account state bucket).

Everything upfront is written and waiting. Read it when you reach it, then go do the hard part yourself.
