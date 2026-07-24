# Least privilege

The rule (ground rule G5): every principal can do exactly what it touches and nothing more. No `"Action": "*"` anywhere except the Terraform admin role. Each Lambda and each ECS task gets its own role scoped to its actual calls.

This isn't security theater. The whole point of the observability half of the project is that when you revoke the fraud-worker's `dynamodb:PutItem` (S24.5), the backlog alarm fires and you *trace it back to an IAM change*. Tight scoping is what makes blast radius small enough to reason about, and it's what an interviewer means by "walk me through how you'd lock this down." Read `identity-accounts-iam` first for the evaluation model; this page is the *method* for writing tight policies.

## The method: scope from access patterns (never trim down)

The wrong instinct is to start from a broad policy and remove things until it breaks. The right one is to start from "what does this component actually call" and grant exactly those. Building **up from denials** is the correct direction: you end with a policy that *documents* what the component does.

1. **List the calls.** For the archiver Lambda: read the HMAC secret from SSM at cold start, consume from `lf-archive-q`, write objects to the archive bucket, write logs, send traces. That's the entire list.
2. **Turn each call into `action` + `resource` + `condition`.**
   - `ssm:GetParameter` on `arn:aws:ssm:...:parameter/lf/dev/webhook-hmac`
   - `sqs:ReceiveMessage` / `sqs:DeleteMessage` / `sqs:GetQueueAttributes` on the `lf-archive-q` ARN
   - `s3:PutObject` on `arn:aws:s3:::lf-archive-<acct>/events/*`
   - `logs:CreateLogStream` / `logs:PutLogEvents` on its own log-group ARN
   - `xray:PutTraceSegments` / `xray:PutTelemetryRecords`
3. **Grant those, explicitly deny nothing (usually), and stop.** Anything you forgot surfaces as a clean `AccessDenied` you then add *deliberately*.

The spec has already done the *listing* for you in each service's "Role may do exactly" column. Your exercise is writing policy JSON that expresses it precisely, not discovering the list.

## Resource-level ARNs and conditions: use them

Many people write `Resource: "*"` because it always works. It also means "every object / queue / table in the account." Prefer:

- **Specific ARNs.** `sns:Publish` on the one topic ARN, not `*`. For DynamoDB, grant the *table* ARN **and** the specific **GSI** ARNs (`.../table/lf-core/index/GSI1`) the component reads; a Query on a GSI is denied if you only listed the table.
- **Conditions to narrow further.** The classic in this project: the SQS queue policy allows `sqs:SendMessage` from `sns.amazonaws.com` **only when** `aws:SourceArn` equals your topic ARN (the confused-deputy fix). That stops any other principal, or any other topic, from stuffing your queue.
- **Prefix / path scoping.** `s3:PutObject` on `.../events/*`, not the whole bucket.
- **Action-family precision.** Grant `sqs:ReceiveMessage`, not `sqs:*`. Wildcarding the *action* is as leaky as wildcarding the resource: `sqs:*` includes `DeleteQueue` and `SetQueueAttributes`, which a consumer has no business doing.

Some actions genuinely **can't** be resource-scoped: a handful of `List*` / `Describe*` calls are account-wide by design. Know which ones, don't fight them, but never let their existence become an excuse to wildcard the ones that *can* be scoped.

## Deny statements and negative conditions: the sharp tools

Most policies are pure Allow. Deny is a scalpel for a few real jobs:

- **A guardrail that survives future edits:** e.g. a `Deny` on `s3:*` when `aws:SecureTransport` is `false` forces TLS regardless of what someone later adds to the Allow side.
- **`aws:SourceIp` / `aws:SourceVpce`** conditions to pin access to a network origin.
- Remember the evaluation rule: a Deny **anywhere** wins. That makes Deny powerful *and* a good way to lock yourself out: reserve it for genuine guardrails, not for "I'll just deny the extra bits" (that's a sign your Allow was too broad to begin with).

Avoid `NotAction`/`NotResource` in Allow statements: "allow everything except X" almost always grants more than you think and is a recurring source of over-privilege.

## The `iam:PassRole` trap

To let a service run something *as* a role (ECS launching a task as `lf-ledger-api-task`, EventBridge Scheduler invoking a Lambda), the **caller** needs `iam:PassRole` **on the role being passed**. This is a frequent, confusing denial because the error is about *passing a role*, not about the thing you thought you were doing.

Scope it hard: grant `iam:PassRole` only on the specific task/exec role ARNs, and add the **`iam:PassedToService`** condition (e.g. `ecs-tasks.amazonaws.com`) so the role can only be handed to the intended service, not, say, to an EC2 instance an attacker spins up. The spec's S06.3 deploy role does exactly this; understand *why* before you copy it. Conceptually: without `PassedToService`, `PassRole` on a powerful role is a privilege-escalation primitive.

## Permission boundaries: the second layer

A boundary is a **ceiling** attached to a principal: its effective permissions are the **intersection** of its identity policy and its boundary. Even if someone later adds `iam:CreateUser` to the identity policy, the boundary blocks it.

You'll feel this in S26.4: attach `lf-deploy-boundary` (allows only ECR/ECS/logs actions) to the deploy role, then add `iam:CreateUser` to the role's identity policy and prove via CLI that creation **still fails**. That's the boundary doing its job. Boundaries are how a platform team lets others create roles *without* letting them escalate: a real staff-level control, and the mechanism behind "you can make roles, but nothing you make can exceed this ceiling."

## Generating and validating policies from evidence

You don't have to hand-derive every policy blind:

- **IAM Access Analyzer *policy generation*** can read CloudTrail and propose a least-privilege policy from the calls a principal *actually made*. Useful as a starting draft you then tighten, never as a blind paste.
- **Access Analyzer *policy validation*** (S26.2): run it against every customer-managed policy; target **zero** security findings. It catches over-broad grants and mistakes you can't eyeball.
- **Access Analyzer *external-access findings*** (S26.3): surfaces any resource reachable from outside the account. In this design the expected answer is "none," so *any* finding is a real leak to chase.
- **Read the live account, not your Terraform** (S26.1): write the IAM inventory by reading what's *actually deployed*. That's how you catch drift between intent and reality (someone clicked something, a policy version differs).

## Where wildcards are acceptable

- **The Terraform admin role** (your SSO admin session) is broad by necessity: it creates everything. That's the one place breadth is expected.
- **A few unscopable `Describe*` / `List*` actions** where AWS offers no resource-level control.

Everywhere else (task roles, Lambda roles, CI roles) a wildcard is a **finding**, not a shortcut.

## Map to your world

Least privilege here is the same instinct as tight Kubernetes **RBAC**: grant the identity only the verbs on the resources it actually uses:

- **Identity policy** ≈ a Kubernetes **RBAC Role/RoleBinding**: verbs on resources, bound to a ServiceAccount.
- **Resource policy with `SourceArn`** ≈ an ACL that permits exactly one named source and drops the rest, like a firewall rule that `permit`s a single host, except the "host" is an AWS identity/ARN, not an IP. It's the resource itself saying "only *this* caller may touch me."
- **`iam:PassRole`** has *no* clean k8s analog; the closest is controlling *who is allowed to set a Pod's `serviceAccountName`*, since that's the "who may run workloads as this identity" question.
- **Permission boundary** ≈ an admission-control policy (Kyverno/OPA-Gatekeeper style) that caps what any Role someone creates is *allowed to contain*.

The AWS-specific additions to internalize are the PassRole step and boundaries: those are the parts your k8s intuition doesn't already cover.

## Primary sources

- **IAM policy evaluation logic** (again, it underpins all of this).
- **"Grant least privilege"** and **"IAM security best practices"** in the IAM docs.
- **IAM Access Analyzer** docs for policy *generation*, policy *validation*, and *external-access* findings.
- AWS's **"confused deputy"** page for the `SourceArn`/`PassedToService` reasoning.
