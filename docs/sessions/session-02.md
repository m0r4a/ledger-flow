# Session 2: Budgets, billing alarm, CloudTrail, and the Terraform backend

**Covers:** finish **S02** (account + Identity Center), then **S03** (budgets & billing alarm), **S04** (CloudTrail), and **start S05** (Terraform backend + repo layout). This is the "money guardrails + audit + first real Terraform" session, and it's the first time you work in the **management account**. Budget ~one focused session; if S05's bootstrap fights you, that's normal; stop at a clean point and carry it into Session 3.

> Read `concepts/identity-accounts-iam.md`, `concepts/terraform-layers-state.md`, and `concepts/cost-and-teardown.md` before starting. They front-load exactly the "why" you'll hit here (two-account split, remote state + bootstrap, the two-mechanism billing alert). ~40 min of reading that saves hours.

---

## The frame for this session

Everything this session is about **two ideas colliding**:

1. **The management account is different.** Billing, budgets, the billing alarm, and the org CloudTrail all live in `mora-management`, not `mora-dev`, because consolidated billing surfaces estimated charges only in the payer account, and an org trail is created from the management account (see `identity-accounts-iam` → "two-account split"). You'll switch to the **`lf-mgmt`** SSO profile for the first time. Getting the profile/account wrong is *the* recurring error this session; before every command, run `aws sts get-caller-identity` in your head first: *which account am I in?*
2. **This is where IaC-only (G1) gets real**, but a few things genuinely can't be Terraform on day one. The skill is knowing which is which, and documenting the exceptions in `docs/bootstrap.md` so the account is still reproducible by instructions.

**Prerequisite you still owe:** the **management account ID**. You need it for the audit bucket name (`lf-audit-<mgmt-acct-id>`, S04.2) and for the `00-org` backend. Have it in front of you before you start.

---

## Decide this first: where does `00-org`'s Terraform state live?

This is a genuine gap in the spec you must resolve before writing the `00-org` layer, and it's a real staff-level call, so **write it up as an ADR**. The spec bootstraps the *dev* state bucket (`lf-tfstate-<dev-acct>`, created by `00-foundation` with local state first, S05.4) but never says where the **management** account's `00-org` state lives. The `00-org` layer runs as `lf-mgmt` against `mora-management`, so it needs a backend that principal can reach.

Options, with the tradeoffs:

- **A, a separate state bucket in the management account** (`lf-tfstate-<mgmt-acct>`), bootstrapped local-state-first exactly like the dev one. *Pro:* clean account boundary (management state stays in management), symmetric bootstrap you already understand, best least-privilege story. *Con:* a second bucket to create and guard with `prevent_destroy`.
- **B, reuse the dev state bucket cross-account**, with a bucket policy allowing the management principal to read/write the `00-org/` key. *Pro:* one bucket. *Con:* cross-account S3 access, management state now depends on a dev-account resource (a coupling that breaks the isolation the account split exists to provide), and a wider bucket policy, a weaker G5 story.
- **C, keep budget/billing/trail as pure console/CLI bootstrap, no Terraform** for `00-org`. *Reject:* these resources *can* be IaC, so leaving them clicked violates G1. Only the genuine exceptions below get that treatment.

**My recommendation: A.** It keeps the account boundary honest, the bootstrap is the same chicken-and-egg you'll do for dev anyway, and it scales cleanly if stretch X4 ever adds more management-account infra. Weigh it yourself and record the decision; this is a good first ADR because the reasoning (isolation versus one-bucket convenience) is exactly the kind of tradeoff interviews probe.

---

## The genuine bootstrap exceptions (document in `docs/bootstrap.md`)

Not everything here can be `terraform apply` on a virgin account. These are the sanctioned exceptions: do them by console/CLI and write the exact steps down so the account is reproducible:

- **IAM Identity Center** (S02.3): bootstrap-by-console, done in Session 1; make sure `docs/bootstrap.md` records the clicks.
- **"Receive Billing Alerts" account preference** (S03.4): the `AWS/Billing EstimatedCharges` metric doesn't exist until you enable this in **Billing preferences**, in the **management** account. The billing alarm has nothing to watch until you do. Console-only, one checkbox, document it.
- **The state-bucket chicken-and-egg** (S05.4, and Option A above): bucket created with **local state first**, then `terraform init -migrate-state`. This is the same class of problem as a Flux/GitOps bootstrap: the thing that will manage state doesn't exist until something creates it.

Everything else this session is real Terraform.

---

## Predict-before-test targets (write these in `my_log.md` before you look)

Three behavioral checks this session, and the knob is ON, so predictions go in the log *first*:

1. **S03.5 billing mechanism test.** Set a temporary $1 budget. *Predict:* how long until the email arrives after you cross the threshold, and what exactly triggers it (actual vs forecasted; is it the budget or the CloudWatch alarm that mails you first?). Billing metrics update on a lag; commit to a number.
2. **S04 CloudTrail visibility lag.** After you create the state bucket, run the S04.3 `lookup-events` for `CreateBucket`. *Predict:* will your just-created bucket show up immediately, and if not, how many minutes until CloudTrail surfaces a management event? (CloudTrail delivery is not instant; predict the lag.)
3. **S05 lock contention.** Start two `terraform apply` runs in the `00-org` layer at once. *Predict:* what does the second one do, and what artifact in the bucket makes it happen? (This is the native S3 lockfile; see `terraform-layers-state`.)

Trivial checks are exempt: S02.6's "`get-caller-identity` shows an `AWSReservedSSO_...` ARN" is a boolean, no prediction needed.

---

## Walkthrough: the "why" and the traps, service by service

I'm not giving you the Terraform. This is the map of *what each piece is for, where it bites, and what "wrong" looks like*; you write the HCL and hit the Verify gates.

### Finish S02: account hardening
- **Root MFA on *both* account roots, zero access keys on either** (S02.1). The management root is the org crown jewel; a compromise there is game over for both accounts. Verify with `aws iam get-account-summary` → `AccountAccessKeysPresent: 0` in each account.
- **Account-level guardrails** (S02.2): default EBS encryption on; S3 Block Public Access at the *account* level (a belt to the per-bucket suspenders you'll set in S09). These are set once per account; remember you have *two*.
- **Trap:** these are per-account settings. It's easy to harden `mora-dev` and forget `mora-management`. Do both, confirm the profile each time.

### S03: budgets & billing alarm (management account, and us-east-1 for the alarm)
- **Two mechanisms on purpose** (see `cost-and-teardown` → "two-mechanism billing alert"): AWS Budgets (`lf-monthly`, $30, alerts at 50/80/100% actual + 100% forecast) is the accounting view; the CloudWatch alarm (`lf-billing-20usd`) on `EstimatedCharges` is the metrics view. One can silently break; two rarely fail together.
- **Region trap:** the billing alarm and its SNS topic (`lf-billing-alerts`) **must be in us-east-1**, the only region the billing metric publishes. Everything else in the project is us-east-2. This is your first real encounter with the us-east-1 exception list; it will confuse you if you forget it (`identity-accounts-iam` and `aws-mental-model` both flag it).
- **Order trap:** the alarm can't be created meaningfully until the "Receive Billing Alerts" preference is on (the bootstrap exception above). Preference first, then alarm.
- **Confirm the SNS email subscription.** An unconfirmed subscription silently drops every alert. This is a real, common miss: the alarm "works" and you never get mail.
- **Then S03.5: test it.** An untested alert doesn't exist. Predict timing, set the $1 budget, receive the mail, delete it.

### S04: CloudTrail (org trail from the management account)
- **This is an *organization* trail** (S04.1), created in `mora-management`, capturing **both** accounts into one bucket: multi-region, **management events only** (data events cost money and generate volume you don't need, see `cost-and-teardown`), log-file validation on.
- **The bucket policy is the subtle part** (S04.2): an org-trail destination bucket policy is **different** from a single-account one: it must authorize the org's *member* accounts to write, not just the management account. If you paste a single-account CloudTrail bucket policy, delivery from `mora-dev` fails. This is the trap S04 is teaching.
- **Skill rep** (S04.3): run one `aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=CreateBucket` and actually read the output. You'll lean on this every time Terraform does something you didn't expect; CloudTrail is your "what actually happened, and who did it" ground truth (`identity-accounts-iam` → triage step 6).

### S05: start the Terraform backend + layout
- **State bucket** (`lf-tfstate-<acct>`, S05.1): versioning ON (your rollback seatbelt), SSE-S3, Block Public Access, keep 30 noncurrent versions. Plus a management-account state bucket if you chose Option A.
- **Bootstrap** (S05.4): local state → add the `backend "s3"` block → `terraform init -migrate-state`. Don't fight the chicken-and-egg; it's a documented one-time step, not a failure.
- **Backend per layer** (S05.2): `use_lockfile = true`, **no DynamoDB lock table** (legacy; know why: the native S3 lockfile replaced it in TF ≥ 1.10; see `terraform-layers-state`).
- **`prevent_destroy`** (S05.12) on the stateful always-on resources (both state buckets, audit bucket, and later the hosted zone/ECR/DynamoDB), so a fat-fingered destroy in the wrong layer errors instead of deleting.
- **`default_tags`** (S05.7) from the very first resource: retrofitting tags is painful and Cost Explorer can't attribute untagged spend (and you'll need to *activate* the tags as cost-allocation tags in Billing, see `cost-and-teardown`, it's a separate step people miss).
- **The `[you decide]` state-wiring ADR** (S05.6) is *flagged* now but you don't exercise it until layers cross-reference each other (Session 7+). Read `decisions/state-wiring.md` when you get there; for this session, just know SSM-over-remote_state is the chosen default and why.
- **You do not need the full repo layout (S05.8) or `just up`/`down` (S05.9) working this session**, since 20/30 don't exist yet. Scaffold the directories, get `00-org` (and the bootstrap of `00-foundation`'s bucket) applying cleanly. The lock Verify runs against `00-org`.

---

## Verify checklist (the gates for this session)

- [ ] **S02.1:** `aws iam get-account-summary` shows `AccountAccessKeysPresent: 0` in **both** accounts; root MFA on both.
- [ ] **S02.6:** `aws sts get-caller-identity --profile lf-dev` returns an `assumed-role/AWSReservedSSO_LedgerFlowAdmin...` ARN (and `--profile lf-mgmt` returns the management-account equivalent). *(trivial, no prediction)*
- [ ] **S03.5:** temporary $1 budget fires an email; you predicted the timing first; deleted afterward.
- [ ] **S04.3:** one `cloudtrail lookup-events` run, output read and understood; you predicted the visibility lag.
- [ ] **S05 (lock):** two concurrent `terraform apply` in `00-org` → the second fails to acquire the lock (predicted first).
- [ ] Billing alarm + its SNS topic exist **in us-east-1**, email subscription **confirmed**.
- [ ] Org CloudTrail delivers events from **both** accounts to `lf-audit-<mgmt-acct>` (check objects land from `mora-dev` too).

---

## Artifacts to leave behind

- **`docs/bootstrap.md`:** Identity Center clicks, the "Receive Billing Alerts" preference, and the state-bucket local→remote migration steps.
- **ADR: `00-org` state location:** Option A/B/C, your choice, the reasoning (isolation versus convenience).
- **`my_log.md`:** `S03 3.5`, `S04 4.3`, `S05` entries with your *predictions* and then the *actuals*, plus anything that surprised you (surprises are the highest-value log lines; they're where a wrong mental model got corrected).

## Definition of done for the session

S02 fully hardened on both accounts; the two billing mechanisms live and **tested**; the org CloudTrail capturing both accounts to one bucket; the `00-org` layer (and the dev state bucket bootstrap) applying cleanly from remote state with the lock Verify passing. If S05 isn't fully there, a clean stopping point is: buckets bootstrapped + `00-org` applying, and carry the repo-layout polish into Session 3 alongside S06 (GitHub OIDC).

---

## When you're ready for the next session

Session 2-3 continues into **S06 (GitHub OIDC + CI)**: passwordless CI, the `sub`-claim fork trap, and `iam:PassRole` scoping. Re-read the OIDC section of `identity-accounts-iam.md` before it. A `sessions/session-03.md` brief will cover it at this same depth.
