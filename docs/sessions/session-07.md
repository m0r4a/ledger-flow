# Session 7: the final exam: IAM hardening, game days, and DR (S26, S27)

**Covers:** the spec's "Session 14+" block: **S26** IAM hardening pass (after everything works) and **S27** resilience: five game days, the load test, the DR drill, and the cost retro. Everything before this proved the system *works*; this session proves *you can operate it, break it safely, and rebuild it from nothing*. **Predict-before-test is fully in force here: every game day gets a written hypothesis first** (the knob is ON and scoped to include all game days).

> Re-read `concepts/least-privilege.md` and `concepts/identity-accounts-iam.md` (policy evaluation) before S26. Re-read `concepts/messaging-fanout.md` (DLQ/redrive, drain) and `concepts/observability-slo.md` (which alarm proves each hypothesis) before S27. This is the session that turns the repo into portfolio evidence: the write-ups matter as much as the actions.

---

## The frame

Two distinct disciplines in one block:

1. **S26, tighten and prove least privilege.** You built roles as you went; now you audit them against reality, run the analyzers, and *prove* a permission boundary actually caps escalation. The mandated 30-minute policy-evaluation read comes first, non-negotiable, because the boundary exercise only makes sense once you can trace an `Allow` through SCP ∩ boundary ∩ identity.
2. **S27, resilience as evidence.** Five game days, a load test to find the real ceiling, and a full DR drill. The rule that makes these worth anything: **write the hypothesis before you run it, and write up honestly, including the ones where you were wrong** (those are worth the most, per the spec).

---

## S26: IAM hardening pass

- **S26.5 first: read the IAM policy evaluation logic doc, start to finish, once. Thirty minutes. Non-negotiable.** Everything else in S26 assumes it.
- **S26.1, inventory from the *live account*, not your Terraform.** Write `docs/iam.md`: every role, its trust policy, its permissions, one sentence of *why*, read from the console/CLI so you **find the drift** between intent and reality. Reading Terraform would hide exactly the drift you're hunting.
- **S26.2, Access Analyzer policy validation:** every customer-managed policy → **zero security findings**. It catches over-broad grants you can't eyeball.
- **S26.3, Access Analyzer (account level):** zero unexpected external-access findings. In this design the expected answer is *none at all*, so **any** finding is a real leak to chase.
- **S26.4, the permission-boundary exercise (the staff-level proof):** attach `lf-deploy-boundary` (allows only ECR/ECS/logs) to `lf-gha-deploy`, then add `iam:CreateUser` to the role's identity policy and **prove via CLI that creation still fails**: the boundary is the intersection, so the identity `Allow` can't exceed it. Revert. Write the evaluation-logic explanation in **ADR-004 in your own words** (this is the one that proves you *understand* the model, not just configured it).

**Predict-before-test:** before S26.4, predict the exact error and *why* (which layer denies it, the boundary, not the identity policy). Before S26.1, predict whether you'll find any drift (you built it all in IaC, so will the live account match?).

---

## S27: game days, load test, DR

Each game day is **hypothesis → method → expected alarms → observed → learnings**. Write the first two columns *before* touching anything.

| Drill | What you do | Predict before |
|---|---|---|
| **GD1** | Kill 1 of 2 api tasks under load | Zero 5xx? (desired=2, dereg delay, health checks) |
| **GD2** | Fraud-worker down 30 min under sustained load | Backlog alarm fires; no loss; convergence + **drain time on restart** via Little's Law |
| **GD3** | Poison-pill flood (50 malformed messages) | DLQ alarm fires; clean **redrive-to-source** after fix |
| **GD4** | Delete the ACM validation record | What breaks, and *when*? (certs don't die instantly, so learn renewal mechanics) |
| **GD5** | Simulate AZ loss (desired subnets → one AZ) | Capacity halves, service survives |

- **GD2 is Little's Law in the wild** (S27 senior note): predict drain time = backlog ÷ (workers × throughput) *before* the restart, then measure. This is the same arithmetic you rehearsed in Session 5's flood test, now under a 30-minute backlog.
- **GD3** uses SQS **redrive-to-source** (native), no hand-written requeue (the `messaging-fanout` DLQ discipline).
- **GD4** teaches that certificates renew, they don't instantly fail: a genuinely non-obvious operational fact.

### R9.2: load test (find the real ceiling)
Use your Go loadgen (`--chaos` version now) to find the ingest path's actual limit: **do you hit the Lambda concurrency cap (your ~50 from `decisions/ingest-concurrency.md`) or the API Gateway throttle (25 rps) first at burst?** Predict first (reasoning: the API GW throttle should bite first for sustained load; the concurrency cap bites first only if service time spikes). Document the numbers.

### R9.3: the DR drill (the actual final exam)
`terraform destroy` **everything, including serverless**, but **export DynamoDB to S3 first** (native export; this is why PITR was dropped, you exercise export/import instead). Then full rebuild + data restore. **Time it. Target RTO < 1 hour.** This uses the documented `prevent_destroy` override (S05.12), the *only* sanctioned destroy of the data layer. If it works, you have genuinely learned IaC. Predict the RTO before you start.

### R9.4: cost retro
After a full month, a Cost Explorer breakdown **by tag**: what each layer cost, what surprised you, what you'd change at 100× traffic. Must contain at least one genuine surprise (`cost-and-teardown`; this is where the data-transfer/cross-AZ traps often show up).

---

## Predict-before-test targets (`my_log.md` first, all of them)

Every game day (GD1-GD5), the load-test ceiling (R9.2), the DR RTO (R9.3), and the boundary-denial (S26.4). Write the hypothesis and the *expected alarm(s)* before each. The wrong-hypothesis write-ups are explicitly the most valuable; don't sand them off afterward.

---

## Verify / acceptance checklist

- [ ] **S26.5:** policy-evaluation doc read start to finish (before S26.4).
- [ ] **S26.1:** `docs/iam.md` written from the live account; drift found (or confirmed none).
- [ ] **S26.2/26.3:** zero Access Analyzer security findings; zero external-access findings.
- [ ] **S26.4:** boundary proven (CreateUser fails despite identity allow); ADR-004 in your own words.
- [ ] **S27 R9.1:** all five game days executed and written up honestly (hypothesis → observed → learnings), including any wrong hypotheses.
- [ ] **S27 R9.2:** ingest ceiling found and documented (which limit bit first, predicted).
- [ ] **S27 R9.3:** DR drill: DynamoDB exported, everything destroyed, rebuilt, data restored & verified by the reconciler; **RTO measured < 1h** (predicted first).
- [ ] **S27 R9.4:** cost retro written with at least one genuine surprise.

## Artifacts to leave behind (this is the portfolio)

- **`docs/gamedays/`:** five write-ups. These + the runbooks + the design doc *are your portfolio* (S27 senior note): a repo with this documentation says "SRE" louder than any cert. Consider blogging each on `blog.gmora.work`.
- **`docs/iam.md`**, **ADR-004** (permission-boundary evaluation logic).
- **The DR drill timing + procedure** (`docs/runbooks/dr-drill.md`), the load-test numbers, the cost retro.
- **`my_log.md`:** every prediction vs actual; the wrong ones flagged, not hidden.

## Definition of done (whole project)

IAM is proven-tight (analyzers clean, boundary demonstrated); all five game days are executed and honestly written up; the ingest ceiling is known; the DR drill rebuilds everything from nothing with data intact under a measured RTO < 1h; and the cost retro exists with a real surprise. At that point the Definition of Done in the spec is met, and more importantly, you've done the hard things you set out to learn from.

---

## After S27

Stretch goals live in Appendix B (Athena over the archive, multi-account with SCPs, etc.), only after S27. But the real completion is the evidence: the game-day write-ups, the ADRs, the runbooks, and a DR drill you can rerun. That body of work is the thing that reads as "has operated cloud infra," which was the whole point.
