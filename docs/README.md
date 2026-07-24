# LedgerFlow docs: the "why" behind the build

> **New here? Read [`general_guide.md`](general_guide.md) first.** It maps the whole project (architecture, every file, the workflow, where you are). This page is just the index.

`ledgerflow-complete.md` is the **what**: terse, parameter-level requirements with Verify gates. This folder is the **why**: the concepts, tradeoffs, failure modes, and mental-model links that turn each cryptic requirement into something you understand before you build it.

What this folder deliberately does **not** contain: step-by-step "create this resource with these arguments" instructions, or the conclusions to the open decisions. You write the Terraform, do the debugging, and reach the ADR conclusions yourself. That split is the point: reading a perfect how-to feels like understanding, but the understanding comes from doing it and getting it wrong.

## How to use it

- **Now, before you build much more:** read the foundational concept pages (`concepts/`). They apply across every session.
- **When you reach a service:** read that service's page and any decision dossier it points to, then build against the spec's Verify lines. You said you'd read just-in-time; the pages are written to be read that way (self-contained, cross-linked).
- **Before a session:** the `sessions/` brief gives the goal, the reading, the predict-before-test targets, and the Verify checklist.
- **When you decide something:** the `decisions/` dossier lays out the options; your conclusion goes in `adr/` as a short ADR.

## Layout

```
docs/
  concepts/     the "why": concepts + tradeoffs + failure modes, linked to your k8s / Cisco-networking / ActiveMQ world
  decisions/    a dossier per [you decide]: options + tradeoffs + interview angles (you write the ADR)
  sessions/     per-session prep: goal, reading, predict targets, Verify checklist
  adr/          your decision records
  runbooks/     your operational procedures (I review)
  gamedays/     your game-day write-ups (S27)
```

## Completeness map

Everything here is written. This is the inventory of what lives in each folder.

**Foundational concepts**
- [x] `concepts/aws-mental-model.md`
- [x] `concepts/identity-accounts-iam.md`
- [x] `concepts/least-privilege.md`
- [x] `concepts/terraform-layers-state.md`
- [x] `concepts/cost-and-teardown.md`
- [x] `concepts/networking-no-nat.md`  (before Session 7)
- [x] `concepts/messaging-fanout.md`  (before Session 4)
- [x] `concepts/dynamodb-single-table.md`  (before Session 4)
- [x] `concepts/observability-slo.md`  (before Session 11)

**Decision dossiers.** All written, with options, tradeoffs, failure modes, my lean, and an interview angle; your ADR conclusion still goes in `adr/`.
- [x] `decisions/state-wiring.md` (S05.6) · [x] `decisions/cert-placement.md` (S18.4) · [x] `decisions/image-base.md` (S19.4) · [x] `decisions/worker-capacity.md` (S21.8) · [x] `decisions/cloudfront-layer.md` (S22.3) · [x] `decisions/canary-schedule.md` (S23.1) · [x] `decisions/tracing.md` (S24.4) · [x] `decisions/ingest-concurrency.md` (S13.13)

**Session briefs** (one per build-arc chunk, all written at full depth):
- [x] `sessions/session-02.md`: budgets, billing alarm, CloudTrail, start Terraform backend (S03/S04/start S05)
- [x] `sessions/session-03.md`: finish backend + passwordless CI/OIDC (S05-rest, S06)
- [x] `sessions/session-04.md`: first end-to-end serverless flow (S07-S14)
- [x] `sessions/session-05.md`: locked-down VPC, containers, edge (S15-S22)
- [x] `sessions/session-06.md`: remaining Lambdas, scheduling, full observability (S13-rest, S23, S24)
- [x] `sessions/session-07.md`: the final exam (IAM hardening, game days, DR; S26, S27)

**Per-service pages** (`services/`, S01-S27, build order), all written:
- [x] S01-S27: each covers purpose, the requirements that carry hidden depth, what the Verify is *really* testing, predict targets, and cross-links. Open the one you're building.

Totals: 9 concept pages · 8 decision dossiers · 6 session briefs · 27 per-service pages, about 46k words. Read just-in-time as you reach each service.

## Related files, not in this folder

- `ledgerflow-complete.md`: the spec (the what).
- `CLAUDE.md`: my operating contract (gitignored); how I work with you, not project docs.
- `my_log.md`: your session log and predictions.
