# Terraform layers, state & backends

You already know Terraform the tool. The new parts here are the **state/backend model** and the deliberate split of the system into independent **layers**. Both exist to serve the teardown discipline: you must destroy the expensive half of the infrastructure every session and rebuild it hands-off, without ever touching the cheap always-on half or your data.

## What state actually is

Terraform's state file is its record of *"what I created, what each thing's real-world ID is, and what I last knew its attributes to be."* It is the mapping between your HCL resource addresses (`aws_sqs_queue.archive`) and real ARNs/IDs, plus a cached copy of every attribute. Three consequences flow from that:

- **`plan` is a three-way diff:** desired (your HCL) vs recorded (state) vs actual (a refresh against the AWS API). Understanding this explains most "why is it planning that?" surprises: usually state and reality disagree (drift).
- **State is sensitive.** It stores resource attributes *in plaintext*, including anything an API returns as an attribute (an RDS password, an access key, a generated secret). This is why the webhook **HMAC secret is never a Terraform-managed value**: it would land in state. You create it out-of-band (CLI/console into SSM SecureString) and Terraform only references it by name.
- **State must be shared, durable, and locked**, which is what the backend provides.

## The remote backend: S3 + native lockfile

- **Durable + shared:** state lives in S3 (`lf-tfstate-<acct>`), **versioned** (a bad apply can be rolled back to a prior state object) and **encrypted**.
- **Locked:** two applies must not run against one state at once. Terraform ≥ 1.10 does this with a **native S3 lockfile**: `use_lockfile = true` writes a lock object beside the state. The older pattern used a separate **DynamoDB lock table**; the spec deliberately skips it (S05.2) because it's now legacy. Knowing *both*, and *why the DynamoDB table is no longer needed*, is an interview-grade detail.

The Verify for this (S05) is concrete and behavioral: start two `terraform apply` runs in one layer simultaneously and watch the second fail to acquire the lock. That's the mechanism proving itself, a predict-before-test item (write down what the second run does *before* you run it).

## Backend configuration and the per-layer profile

Each layer's `backend "s3"` block names the bucket, the **state key** (its path in the bucket, e.g. `00-org/terraform.tfstate`, `20-network/terraform.tfstate`), the region, and the AWS **profile**. Because `00-org` targets `mora-management` and the rest target `mora-dev`, the profile differs per layer (`lf-mgmt` vs `lf-dev`). You can keep environment-specific bits out of committed HCL with **partial backend configuration** (`terraform init -backend-config=...`), which matters more once there are multiple environments; for now, one key per layer is enough.

## The bootstrap chicken-and-egg

The bucket that stores state is *itself* Terraform-managed, but Terraform needs a backend to run, and the backend is the bucket that doesn't exist yet. You resolve it exactly like a GitOps bootstrap (your Flux install-before-the-cluster-manages-itself step): create the bucket with **local state first**, then add the `backend "s3"` block and run `terraform init -migrate-state` to move the local state into the bucket it now manages. Document the sequence in `docs/bootstrap.md` so the account is reproducible by instructions even though this one step can't be a pure `apply`.

## Why split into layers

A "layer" is an independent Terraform **root** with its own state file. This project has five:

| Layer | Account | Lifecycle | Roughly |
|---|---|---|---|
| `00-org` | management | forever | budgets, billing alarm, org CloudTrail |
| `00-foundation` | dev | forever | hosted zone, ECR, state bucket, cert A, OIDC |
| `10-serverless` | dev | always-on, cents | API GW, Lambda, SNS, SQS, DynamoDB, S3 |
| `20-network` | dev | **destroyed each session** | VPC, subnets, SGs, VPC endpoints |
| `30-compute` | dev | **destroyed each session** | ALB, ECS |

Three reasons the extra plumbing is worth it:

1. **State blast radius.** A mistake (or a `destroy`) in one layer physically cannot touch another layer's resources; they're in different state files. You can nuke `30-compute` with total confidence that DynamoDB in `10` is untouched.
2. **Independent lifecycle.** `just down` destroys only 20 and 30 (the hourly billers); 00 and 10 keep serving. One state per lifecycle makes this a two-line operation instead of a surgical `-target` dance.
3. **Faster, safer plans.** A change to the ALB doesn't refresh and re-plan the entire account: smaller state means faster feedback and a smaller surface for a plan to surprise you.

The cost of the split is that layers must reference each other's outputs *across state boundaries*, the subject of the next section.

## Cross-layer wiring: SSM parameters (chosen) vs `terraform_remote_state`

Layer 30 needs the VPC ID and subnet IDs that layer 20 created. Three ways to read across the boundary, in increasing tightness:

- **`terraform_remote_state`:** layer 30 reads layer 20's *entire state file*. Simple, but it grants the reader visibility into **everything** in that state (including any sensitive attribute), which is a weaker least-privilege story and couples 30 to 20's internal structure.
- **Plain `data` sources:** look the resource up live by tag/name. Works, but relies on stable naming and does a live API lookup every plan.
- **SSM parameters (this project's default, S05.6):** layer 20 *writes* exactly the values it wants to publish to `/lf/dev/tf/20-network/<name>`; layer 30 reads just those via a `data "aws_ssm_parameter"` source. You share exactly the handful of values that cross the boundary (VPC/subnet/SG IDs, ARNs) and nothing else, a published *interface* between layers rather than a shared internal.

Because the cross-layer value set is small and well-defined, SSM is chosen here. It's written up as a real decision in `decisions/state-wiring.md` (with remote-state-plus-read-only-role as the noted alternative), so you can *defend* it rather than cargo-cult it.

**The failure mode to expect:** if you destroy layer 20, its published SSM parameters disappear, so layer 30 can no longer even `plan`; its `data` lookups fail. This is **correct**: you shouldn't be able to plan compute when its network is gone. But it makes ordering *load-bearing*: `up` applies 20 then 30, `down` destroys 30 then 20. A partial apply that leaves things half-wired is what wedges you; the `just up` / `just down` targets exist to make the ordering automatic and boring.

## Refactoring without destroying: import, moved, state ops

Real infra work is mostly *changing* existing state safely. The tools, none of which involve hand-editing the JSON:

- **`import` blocks** (or `terraform import`) adopt a resource that already exists (e.g. something created during bootstrap, or clicked into being before you codified it) into Terraform's management without recreating it.
- **`moved` blocks** rename or restructure resources (`aws_sqs_queue.q` → `aws_sqs_queue.archive`, or into a module) and tell Terraform "this is the same object," so it updates the address instead of destroy+create. This is how you refactor without downtime.
- **`terraform state` subcommands:** `mv`, `rm`, `show` for the rare surgical case. Reach for these, never a text editor on the state file; a corrupted state is worse than any mistake they'd fix (and the bucket's versioning is your seatbelt).

## Drift, and the G1 discipline

**Drift** is when reality no longer matches state, almost always because someone clicked something in the console (which violates G1: IaC only, console is read-only). Detect it deliberately:

- `terraform plan` shows drift as a diff (something changed underneath you).
- `terraform plan -refresh-only` isolates *"what changed in reality"* from *"what I want to change,"* which is the clean way to audit for drift without proposing your own edits.

The fix is always to **codify or revert**, never to reconcile by hand. Catching drift is part of the discipline, not an interruption to it: in a Flux world the reconciler would silently correct it; here *you* are the reconciler, on purpose, because noticing the drift is the lesson.

## Provider aliases: multi-region and multi-account

One Terraform root often needs more than one provider configuration:

- **Multi-region.** CloudFront's ACM cert and the billing alarm must live in `us-east-1` while everything else is `us-east-2`. Declare a second `aws` provider with `alias = "us_east_1"` and point those resources at it via `provider = aws.us_east_1`. S18.2's cert B is exactly this.
- **Multi-account.** `00-org` runs against `mora-management` (profile `lf-mgmt`); the rest against `mora-dev` (profile `lf-dev`). Each layer targets one account via its backend/provider profile, so you don't need cross-account role assumption yet.

## default_tags

Set `default_tags` once in the provider (`project = ledgerflow`, `layer = <NN-name>`, `managed-by = terraform`, `repo = ...`) and every resource inherits them. This is what lets Cost Explorer answer "what did the ALB actually cost me," and what proves in one query that a resource is Terraform-managed (anything *without* the tags is drift). It's governance for free: do it from the first resource, not retrofitted. (Caveat worth knowing: a few resources with their own `tags` can interact with `default_tags` in ways that show a perpetual diff; the provider docs cover the merge behavior.)

## prevent_destroy guards

The always-on stateful resources (hosted zone, state bucket, audit bucket, ECR repos, DynamoDB table) carry `lifecycle { prevent_destroy = true }` (S05.12), so a fat-fingered `terraform destroy` in the wrong layer can't erase your data or your DNS: the apply *errors out* instead of deleting. The one sanctioned exception is the DR drill (R9.3), which has a documented one-line override procedure. This is the guardrail that lets teardown be *aggressive and boring*: you can destroy the session layers freely because the irreversible things are pinned.

## Failure modes to expect

- **Lock contention:** expected and healthy; the mechanism working (Verify S05).
- **State drift:** a console change; `plan` shows it; codify or revert, never hand-edit.
- **"Layer 30 can't plan":** layer 20 is destroyed and its SSM outputs are gone. Not a bug, an ordering signal.
- **Partial apply:** an apply that failed midway leaves real resources not fully wired. Re-run; Terraform is convergent. If a single resource is stuck, `terraform state` subcommands are the tools, not the JSON.
- **`prevent_destroy` blocks a destroy you actually meant:** that's the guard doing its job; use the documented override, don't delete the lifecycle block casually.

## Map to your world

Layers are like separate **Flux Kustomizations / Helm releases** with explicit ordering: each reconciles its own slice and you sequence them. State is the equivalent of the cluster's actual object store: the source of truth a reconcile diffs against. Drift is what Flux would otherwise *silently* correct; here you correct it deliberately, because catching it is part of the G1 discipline rather than an automated background fix. And `prevent_destroy` is your equivalent of a finalizer / deletion-protection annotation on the resources you can't afford to lose.

## Primary sources

- **Terraform S3 backend** docs: the `use_lockfile` section specifically.
- The **Terraform AWS provider** docs and **Style Guide**: treat as canon, as you already do; read the `default_tags` and `lifecycle` sections.
- HashiCorp's guidance on **structuring configurations** (separate states per lifecycle vs workspaces) for the layering rationale.
- The docs on **`import`** and **`moved`** blocks: the safe-refactoring toolkit.
