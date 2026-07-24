# Identity, accounts & IAM

This is the hardest and most confusing area in AWS, and the one interviewers probe most, so it gets the longest page. If you internalize (a) the trust-vs-permission split, (b) the evaluation order, and (c) the ARN/condition-key vocabulary, most `AccessDenied` mysteries stop being mysteries and start being a five-step checklist.

## Three different systems that all say "identity"

They stack, and people conflate them constantly.

- **AWS Organizations:** the *account* container. One management (payer) account, zero or more member accounts, consolidated billing, and two kinds of org-wide guardrails:
  - **SCPs (Service Control Policies):** a ceiling on what any principal *in a member account* can be granted. SCPs never grant anything; they only subtract.
  - **RCPs (Resource Control Policies):** a ceiling on what any *resource policy* in the account can grant (e.g. "no bucket in this org may be made public"), launched late 2024.
  You have an org: `mora-management` + `mora-dev`.
- **IAM Identity Center** (formerly AWS SSO) is *workforce* sign-in. It holds **you** as a human user, defines **permission sets** (a named bundle of policies + a session duration), and *assigns* a permission set to you in specific accounts. `aws sso login` exchanges your browser session for short-lived assumed-role credentials in the target account. This is why `aws sts get-caller-identity` shows `assumed-role/AWSReservedSSO_.../Mora` and never an IAM user: you are always a temporary assumed role. Identity Center **requires** an Organization (enabling it is what created your org).
- **IAM** is *per-account* permissions: **roles**, **policies**, and **users** (which you deliberately don't create). This is where the *machine* identities live: each Lambda and each ECS task runs as an IAM **role**.

The mnemonic: **Organizations = which accounts and their ceilings. Identity Center = how humans log in. IAM = what anything can do inside one account.**

## Anatomy of an ARN (the address of everything)

Every resource and identity has an **Amazon Resource Name**. You'll read and write hundreds of these, so learn the shape:

```
arn:aws:sqs:us-east-2:297318163711:lf-archive-q
 │   │   │      │            │            │
 │   │   │   region      account-id   resource
 │   │  service
 │  partition (aws | aws-us-gov | aws-cn)
scheme
```

Some services add a resource *type* segment (`arn:aws:iam::297318163711:role/lf-ingest`) and some are global so the region field is empty (IAM, S3, Route 53). Policies match on ARNs, wildcards are allowed *within* an ARN (`arn:aws:s3:::lf-archive-297318163711/events/*`), and a lot of least-privilege work is writing ARNs precisely instead of `*`.

## Principal types: who can be an actor

A **principal** is anything that can make a request. Knowing the types tells you what a trust policy can name:

- **AWS account root:** the account's original login. Locked away behind MFA and never used (spec S02).
- **IAM user:** a static identity with long-lived access keys. **Banned here** (G4).
- **IAM role:** an assumable identity that yields *temporary* STS credentials. Everything is this.
- **Federated identity:** a human (via Identity Center / SAML) or a workload (via OIDC, e.g. GitHub Actions) that assumes a role.
- **AWS service principal:** a service acting on your behalf, named like `ecs-tasks.amazonaws.com` or `lambda.amazonaws.com`. Trust policies name these so a service can assume a role.

## Users vs roles, and why you have zero users

An IAM **user** carries long-lived credentials, and long-lived keys are the single thing that most often leaks and gets an account owned. So this project bans them (G4) and makes *everything* a **role**: an identity you *assume* to receive temporary credentials from **STS**, which expire (8h for your SSO session; minutes-to-hours for services).

- You (human) assume a role via Identity Center SSO.
- GitHub Actions assumes a role via OIDC.
- Each Lambda/ECS task assumes its role automatically at runtime.

**Map to your world:** an IAM role is close to a Kubernetes **ServiceAccount**, an identity a workload runs as. The piece AWS adds with no clean k8s analog is the **trust policy**.

## The split that explains everything: trust policy vs permission policy

Every role carries two policies doing two unrelated jobs. Confusing them is the #1 source of pain.

- **Trust policy** (a.k.a. assume-role policy) answers **WHO can become this role.** It lives on the role, and its `Principal` names the service/account/OIDC-provider allowed to assume it, usually narrowed by conditions. For an ECS task role: `Principal: {"Service": "ecs-tasks.amazonaws.com"}`. For the GitHub deploy role: the OIDC provider plus a condition on the `sub` claim.
- **Permission policy** (identity policy) answers **WHAT this role can do** once assumed: `sns:Publish` on this topic ARN, `dynamodb:Query` on this table ARN.

When a role "doesn't work," decide first which of these is wrong, because they're debugged in completely different places:
- *"The principal can't assume the role at all"* → **trust-policy** problem (the `sts:AssumeRole` / OIDC exchange failed).
- *"It assumed the role fine but then got denied on the action"* → **permission-policy** problem.

## The policy documents themselves

A policy is JSON: a list of **statements**, each with `Effect` (Allow/Deny), `Action` (the API operations), `Resource` (ARNs), and optional `Condition`. Two shape-traps worth knowing early:

- **`NotAction` / `NotResource`** invert the match ("everything *except* these"). They read as convenient and are a classic way to accidentally grant far more than intended; avoid unless you can articulate exactly why.
- **Managed vs inline.** A *managed* policy is a standalone object you attach to many principals (AWS-managed like `AdministratorAccess`, or customer-managed, versioned). An *inline* policy is embedded in one principal and dies with it. Prefer customer-managed for anything reused; inline is fine for a one-off role-specific grant.

## The policy types and how they combine

A single API call can be touched by up to five policy layers. You need the shape in your head:

1. **Identity policies:** attached to the principal (role). *Grant* actions.
2. **Resource policies:** attached to the resource: S3 **bucket policies**, SQS **queue policies**, SNS **topic policies**, KMS **key policies**, Lambda resource policies. These can grant access to principals *from other accounts* and can also explicitly **deny**.
3. **Permission boundaries:** a *ceiling* on a principal. Its effective permissions are the **intersection** of its identity policy and its boundary. Used in S26.4.
4. **SCPs:** an org-level ceiling on what identities in the account may do.
5. **RCPs / session policies:** RCPs cap what resource policies can grant; session policies (passed at assume-role time) further narrow a session.

**Evaluation logic, memorize this shape:**

- Default is **deny**.
- An **explicit `Deny` anywhere always wins**, full stop, whether identity, resource, boundary, SCP, or RCP.
- Otherwise the request needs an **explicit `Allow`**, *and* it must survive **every** applicable ceiling: `SCP ∩ boundary ∩ session policy`, and for cross-resource access the resource policy (and RCP) as well.

So **"allowed"** means: *some* Allow exists, *no* Deny exists anywhere, and *no* ceiling excludes it. This is the 30-minute mandated read in S26.5; do it before the boundary exercise, and it pays for itself immediately.

## Same-account subtlety: when do you need the resource policy too?

Within **one account**, for most services, an **identity-policy allow is sufficient**: you do *not* also need the resource to allow you. The resource policy becomes decisive when:

- the caller is in **another account** (then you need *both* an identity allow on the caller side *and* a resource allow on the resource side), or
- you want the resource to actively **restrict** who touches it (the spec leans on this: the SQS queue policy allows *only* SNS with a `SourceArn` condition; the status S3 bucket allows *only* the CloudFront distribution).

**S3 and KMS are the notable "both sides matter more often" cases.** And always remember: an explicit **Deny** in a resource policy overrides an identity Allow.

## Condition keys and the confused-deputy problem (staff-level)

Conditions are how you go from "allowed in principle" to "allowed only in exactly this situation." The ones this project uses, and the reasoning:

- **`aws:SourceArn` / `aws:SourceAccount`** solve the **confused deputy** problem. When SNS delivers to your SQS queue, SNS is a *deputy* acting on someone's behalf; without a condition, *any* SNS topic (even another account's) that knows your queue ARN could be authorized by a naive `Principal: sns.amazonaws.com` grant. Pinning `aws:SourceArn` to *your* topic ARN means "only messages originating from my topic." This is the single most important condition pattern in the whole project; understand it before you write the queue policy.
- **`aws:PrincipalOrgID`**: "only principals from my organization," a clean way to scope cross-account resource policies without listing account IDs.
- **`aws:SecureTransport`**: deny non-TLS access to a bucket.
- **`StringEquals` on an OIDC `sub`/`aud`**: the GitHub trust condition below.

## STS and assume-role, concretely

**STS (Security Token Service)** issues temporary credentials: an access key, a secret, **and a session token**, with an expiry. Both `aws sso login` and OIDC federation end in an `AssumeRole*` call that returns this triple; nothing here ever stores a permanent secret. Extra mechanics worth knowing:

- **Role chaining:** an assumed role assuming another role (capped at 1h sessions). Not needed yet (each layer targets one account) but it's how multi-account access works at scale.
- **External ID:** a shared secret in the trust policy used when a *third party* assumes a role into your account (the confused-deputy fix for cross-account vendor access). You don't need it here but interviewers ask.
- The session ARN encodes *how* you got in, which is why the SSO role ARN looks the way it does. Duration comes from the permission set (spec: 8h).

## GitHub OIDC: passwordless CI, and the fork trap

CI must deploy while holding **no** stored AWS secret. OIDC solves this: GitHub Actions mints a short-lived signed **JWT**; you register GitHub's **OIDC provider** in IAM as trusted; the role's trust policy validates the token's claims. The claims that matter:

- **`iss`**: the issuer (`token.actions.githubusercontent.com`), matched by the provider.
- **`aud`**: the audience (`sts.amazonaws.com`), which you check so a token minted for some other audience can't be replayed here.
- **`sub`** identifies *exactly which repo/branch/context* is calling, e.g. `repo:m0r4a/<repo>:ref:refs/heads/main`. Your trust policy pins this with `StringEquals` (or a *carefully* bounded `StringLike`).

**The fork trap the spec hammers:** if you wildcard the repo segment of `sub` (or use a sloppy `StringLike`), *any fork's pull request could assume your deploy role*. That's why S06.3 pins `sub` to `main` exactly, and S06.2's plan role is scoped to `pull_request` with read-only permissions. The Verify (a fork PR cannot assume either role) is testing your grasp of the `sub`/`aud` claims, not AWS itself.

**Map to your world:** this is the same pattern as OIDC into a kube-apiserver: an external IdP vouches for an identity and a trust rule maps a claim to permissions. The `sub` condition is the RoleBinding subject match; the `aud` check is the token-audience validation your apiserver does.

## This project's two-account split

| Lives in `mora-management` | Lives in `mora-dev` |
|---|---|
| Billing, budgets, billing alarm (us-east-1) | Everything else: the whole workload |
| Org CloudTrail (all accounts → one bucket) | State bucket, all app resources, CI/OIDC roles |
| IAM Identity Center (the org's directory) | Per-Lambda / per-task roles |

CI (GitHub OIDC) only ever touches `mora-dev`. You authenticate to each account with a separate SSO profile (`lf-mgmt` and `lf-dev`), and no cross-account role assumption is needed yet because each Terraform layer targets exactly one account.

## Failure-mode triage: reading `AccessDenied`

When you hit `AccessDenied`, walk it in this order, the checklist that turns the mystery into a lookup:

1. **Which identity is actually calling?** `aws sts get-caller-identity`. Nine times out of ten early on, you're on the wrong profile/role or the wrong account.
2. **Trust problem or permission problem?** Could the principal even *assume* the role, or did it assume fine and then get denied on the action? (Different fixes, different files.)
3. **Read the message text.** Modern denials often name the policy *type* and sometimes the exact SCP/boundary: *"with an explicit deny in a service control policy"* points at the **org** level, not your identity policy; stop editing the role and go look at the SCP.
4. **Is there a resource policy in play?** For S3/SQS/SNS/KMS/Lambda, check the resource side too, including an explicit deny there.
5. **Is it actually `iam:PassRole`?** To hand a role to a service (let ECS run a task *as* `lf-ledger-api-task`, let EventBridge Scheduler invoke a Lambda), the **caller** needs `iam:PassRole` on that role, ideally with an `iam:PassedToService` condition. "Can't launch the task" frequently means a missing PassRole, not a missing task permission. (Full treatment in `least-privilege`.)
6. **Backstop: CloudTrail.** Every denied management call is recorded (S04). `aws cloudtrail lookup-events` shows exactly what was attempted, by which principal, and often the deciding policy: your forensic ground truth when reasoning fails.

## Primary sources

- **IAM policy evaluation logic** (the official docs page): the mandated 30-minute read; the flowchart is the whole game.
- **IAM Identity Center** docs for permission sets and assignments.
- The **GitHub Actions "Configuring OpenID Connect in Amazon Web Services"** guide for exact `sub`/`aud` claim formats.
- AWS's **"The confused deputy problem"** docs page: short, and it makes the `SourceArn` condition click.
