# Cost model & teardown discipline

The budget ($30/mo hard ceiling, $15 target) isn't a constraint bolted onto the project; it's a design driver. The architecture, the layer split, and the teardown reflex all fall out of one question asked of every service: **how does this bill?** Learn to ask that reflexively and you've absorbed the most transferable skill in the whole project, because in real shops the billing shape of a service shapes architecture more than performance does.

## Three billing shapes

| Shape | Examples | Behavior |
|---|---|---|
| **By the hour, whether idle or not** | ALB, Fargate tasks, NAT Gateway, **interface VPC endpoints** | The dangerous ones. Cost accrues while they *exist*, traffic or not. |
| **Per use, fractions of a cent** | Lambda invocations, SQS/SNS requests, DynamoDB on-demand, S3 requests/storage | Effectively free at your volumes. Safe to leave running. |
| **Flat and tiny** | Route 53 hosted zone ($0.50/mo), ACM certs (free), ECR storage (~$0.10/GB-mo) | Set-and-forget. |

The whole trick is to keep the hourly things in layers you **destroy** and everything else in layers that **stay up**: exactly the 00/10 (always-on) vs 20/30 (session-only) split. When you meet any new service, put it on this table *first*, before you design with it.

## The pricing dimensions that actually matter per service

"How does it bill" has sub-dimensions. The ones worth carrying in your head for this project:

- **Lambda:** priced on **GB-seconds** (memory × duration) plus a tiny per-request fee. More memory = faster *and sometimes cheaper* because duration drops; the cost/latency sweet spot is a real tuning exercise. Provisioned concurrency (which you're *not* using) bills hourly like a server, a trap to know exists.
- **SQS / SNS:** per **request** (a batch of up to 10 messages is one request; batching is a 10× cost lever). At your volumes: pennies.
- **DynamoDB on-demand:** per **read/write request unit**, plus storage. On-demand means no idle capacity charge (scales to zero), which is why the spec chose it over provisioned; you don't pay for a table sitting there. Item size rounds *up* to the next unit, which is one more reason money is stored as integer cents, not a bloated struct.
- **S3:** storage (GB-mo) **+ per-request** (PUT costs ~10× a GET) **+ retrieval/tier**. Lifecycle rules to cheaper tiers matter at scale; here volume is tiny.
- **ALB:** a base hourly rate **+ LCUs** (a blended unit over new connections, active connections, processed bytes, and rule evaluations). At your traffic the base hourly rate dominates.
- **Fargate:** per **vCPU-second and GB-second** the task runs, billed while the task exists.
- **CloudWatch:** per **custom metric**, per **GB of logs ingested**, per **alarm**, per **dashboard**. This one can out-cost your compute if you're sloppy (its own section below).

## The hourly offenders in this project

From Appendix A, the things that actually move your bill:

- **ALB:** ~$0.0225/hr plus a little per-LCU. ~$0.80 over a 9-hour weekend session.
- **Fargate:** three small tasks ~$0.04/hr total. ~$0.40/weekend.
- **Interface VPC endpoints:** the sneaky one. Six of them at ~$0.01/hr each ≈ $0.06/hr ≈ $0.55/weekend, and they bill *even though "an endpoint" feels like it should be free*. This is why S16 lives in layer 20 and dies with `just down`.
- **NAT Gateway:** the one you never build. It would be ~$0.045/hr **plus** ~$0.045/GB processed, and it's the classic surprise bill (the per-GB part is what wrecks people, since a chatty workload behind NAT bleeds money). This project routes around it entirely: private subnets with no default route, VPC endpoints for AWS APIs. That's a deliberate lesson as much as a saving.

Everything else, the entire serverless ingest path, is cents per month even without free tier.

## The data-transfer trap (the bill nobody predicts)

Compute and storage are easy to reason about; **data transfer** is where real AWS bills hide, and it's worth knowing even though this project is engineered to dodge most of it:

- **Out to the internet** costs per GB (inbound is free). CloudFront in front of S3 is partly a cost play: cached bytes don't re-egress from origin.
- **Cross-AZ traffic** costs ~$0.01/GB *each way*, even inside one VPC. A chatty service talking to a database in another AZ pays for it continuously, which is why AZ-aware placement is a cost concern, not just a latency one.
- **Through a NAT Gateway** you pay the per-GB processing fee *on top of* egress: the compounding reason NAT is avoided here.
- **Gateway VPC endpoints (S3, DynamoDB) are free**; **interface endpoints bill hourly + per-GB**. So the S3/DynamoDB gateway endpoints are pure savings, while the interface endpoints (ECR, logs, SSM, etc.) are the hourly cost you tear down.

The takeaway: when a future design "just adds a call between two components," ask *which direction the bytes cross and through what*. That instinct is what separates a senior cost review from a junior one.

## Teardown discipline

`just down` destroys layers 30 then 20 at the end of every session; `just up` brings them back. The habits that make this safe:

- **Rebuild must be boring.** If bringing the stack back feels risky, your IaC is wrong. The measure of done is `just down && just up` completing hands-off (Verify S05).
- **Verify zero, don't assume zero.** `just status` prints ALB count, ECS service count, and NAT-gateway count (should be 0). Glance at it before you close the laptop. "I ran destroy" is not the same as "the console shows zero." This is a behavioral predict-before-test candidate: predict the counts, then look.
- **The always-on half is genuinely fine to leave up.** The serverless path is designed to cost cents 24/7: that's the *reward* for putting it on the right side of the billing line, and tearing it down would just add rebuild friction for no saving.

## The two-mechanism billing alert

One alert can silently break; two rarely fail together. So:

1. **AWS Budgets** (`lf-monthly`, management account): actual alerts at 50/80/100% of $30 plus a forecast alert. The accounting-side view.
2. **CloudWatch billing alarm** (`lf-billing-20usd`, management account, **us-east-1**): watches the `EstimatedCharges` metric directly. The metrics-side view.

They live in the **management** account because consolidated billing surfaces estimated charges there, not in member accounts (see `identity-accounts-iam`), and in **us-east-1** because that's the only region the billing metric is published. Critically, **test them** (S03.5): temporarily set a $1 budget, receive the email, delete it. An untested alert doesn't exist; you'll believe you're covered right up until the month you aren't. This is a predict-before-test target: before the test, write down how long until the email arrives and what triggers it.

## Cost-allocation tags are not automatic

`default_tags` puts `project`/`layer`/`managed-by` on every resource, but tags don't appear as Cost Explorer filters until you **activate them as cost-allocation tags** in the Billing console (a management-account, one-time step), and activation only affects billing data *going forward*, not retroactively. So do it early. Until a tag is activated, "group by tag" in Cost Explorer simply won't offer it, a confusing gap if you don't know the activation step exists.

## CloudWatch is itself a cost trap

Observability can quietly out-cost your compute if you're careless:

- **Custom metrics bill per metric-stream** (~$0.30/mo each after free tier). Every unique metric × dimension-value combination is a separate stream, so a metric with a high-cardinality dimension (say, per-customer-ID) can silently explode into thousands of streams. The spec keeps total custom streams under 10 and uses dimensions sparingly for exactly this reason.
- **EMF (Embedded Metric Format) over `PutMetricData`.** EMF emits metrics as structured log lines that CloudWatch extracts asynchronously, so you're not paying for (or blocking on) synchronous metric API calls in hot paths. The spec mandates EMF and bans `PutMetricData` in hot paths (S24): a real cost-*and*-latency decision, not a style preference.
- **Log retention.** Auto-created log groups keep logs **forever** by default. Every log group here is Terraform-managed with 14-day retention so storage doesn't creep.
- **Logs bill on ingestion (per GB) more than storage.** So a debug-logging spree in a hot Lambda is a cost event, not just noise: another reason structured, deliberate logging beats `printf` everywhere.
- **CloudTrail management events only.** *Data* events (every S3 object op, every DynamoDB item op) cost money and generate huge volume; you don't need them here, so the trail is management-events-only (S04).

## Free-tier absence (your situation)

You don't have free-tier credits. This changes remarkably little, because the things that could actually run up a bill were never free-tier anyway (ALB, Fargate, endpoints), and those are exactly what teardown kills. The always-on serverless layer without free tier is still low single-digit dollars a month at your volumes. Don't pre-spend headroom you don't need; keep the $30 ceiling. The one place going higher genuinely helps is if you *deliberately* leave the compute layer up for a few extra hours to explore something; do that consciously, while watching the alarm.

## Cost-related failure modes

- **Forgot teardown overnight.** The billing alarm catches it; the `just status` reflex prevents it.
- **Left one interface endpoint behind.** They bill individually; `just status` and Cost Explorer by tag will show it.
- **Runaway loadgen loop.** Why the ingest path has *both* an API Gateway throttle (25 rps) **and** reserved concurrency on the ingest Lambda: two independent ceilings so a bug can't fan out to 1000 concurrent executions all publishing downstream (which would also multiply SQS/SNS/DynamoDB request costs).
- **A stray data-event trail or a chatty custom metric.** Slow leaks, caught by the weekly two-minute Cost Explorer glance filtered by your tags.
- **Cross-AZ chatter you didn't notice.** A component placed in the wrong AZ relative to what it talks to, invisible until you read the data-transfer line in Cost Explorer.

## Map to your world

Your homelab hardware is a sunk cost, so leaving things running is free and you never had to build a FinOps reflex, which is precisely the muscle this project trains. Here **idle equals money**, and the discipline (tag everything, activate the tags, watch the meter, tear down the hourly stuff, verify zero, notice where bytes cross) is a real skill that transfers directly to any cloud role. The cost retro at the end (R9.4: what each layer cost, what surprised you, what you'd change at 100× traffic) is where this becomes portfolio evidence: the kind of thing that reads as "has actually operated cloud infra," not "has done a tutorial."

## Primary sources

- **AWS Well-Architected, Cost Optimization pillar.**
- The **AWS Pricing Calculator** (prices drift; verify the numbers in Appendix A rather than trusting them).
- The **"Understanding data transfer charges"** docs / the *Overview of Data Transfer Costs for Common Architectures* whitepaper: the trap most people learn about from a bill.
- **Cost Explorer** with tag filters: your weekly two-minute check (after you've activated the tags).
