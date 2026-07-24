# The AWS mental model

The single unlock, before any service: **AWS is not a pile of machines you log into. It is a few hundred independent API services, each fronted by IAM, each living in a region.** Almost everything you do is an authenticated HTTPS API call. "Create a queue" is an API call. "Run a container" is an API call. "Read an object" is an API call. Even "give me temporary credentials" is an API call (to STS). When something doesn't work, the question is almost never "is the box up." It's *"was this API call authenticated, was it authorized, was there a network path to the API endpoint, and did I shape the request correctly."*

That reframing matters because your instincts are from Kubernetes and bare metal, where there's a cluster with a shared flat network, a scheduler, and a node you can SSH into. AWS gives you none of that by default. There is no shared network until you build a VPC. There is no implicit trust between services; every hop is IAM. There is no node to SSH into for a Lambda or a Fargate task (you get ECS Exec; Lambda has none, and ECS Exec is itself an IAM-gated API call that opens an SSM session).

## Anatomy of an AWS API call

Understanding what actually happens on one call demystifies most of AWS. When you run `aws sqs send-message --queue-url ...`:

1. **The SDK/CLI resolves an endpoint.** Every regional service has a DNS name like `sqs.us-east-2.amazonaws.com`. The region is part of the hostname. This is why "wrong region" is such a common early bug: you're literally talking to a different copy of the service that has never heard of your queue.
2. **It signs the request with SigV4.** Your credentials (an access key + secret + session token, all temporary in this project) are used to compute an HMAC signature over the request. The secret is never sent; the signature proves you hold it. This is why a clock skew or a malformed request breaks auth in confusing ways: the signature covers headers, time, and body.
3. **The service authenticates** (who are you, which principal do these creds map to?) **then authorizes** (is this principal allowed this action on this resource? This is the full policy evaluation from `identity-accounts-iam`).
4. **The request hits the control plane or the data plane** (below), does the work, and returns JSON.

The CLI and Terraform are both just ergonomic wrappers over exactly this. When you debug, you're always debugging one of these four stages: endpoint/region, signing/credentials, authorization, or request shape.

## Control plane vs data plane: an essential distinction

Almost every AWS service is split in two, and the split explains a lot of behavior:

- **Control plane:** the management APIs that *create, configure, and describe* resources: `CreateQueue`, `CreateFunction`, `RunTask`, `PutBucketPolicy`. These are lower-throughput, often **eventually consistent** (a role you just created may take a second to be usable; an S3 bucket policy takes a moment to propagate), and this is what Terraform drives. CloudTrail's management events record these.
- **Data plane:** the high-throughput APIs that *use* an existing resource: `SendMessage`, `Invoke`, `GetObject`, `PutItem`. These are engineered for scale and low latency, and are what your running application calls.

Why you care: control-plane eventual consistency causes "it worked on the second `terraform apply`" moments (a dependency wasn't visible yet). And the reliability properties differ: AWS designs data planes to keep working even during control-plane impairment. When you read the Builders' Library later, this distinction is everywhere.

## The account / org / region / AZ model

- **Account:** the hard boundary. It is simultaneously a **billing boundary**, a **security/isolation boundary**, and a **quota boundary** (service limits are per-account-per-region). Resources in one account cannot see resources in another unless you *explicitly* bridge them (an assumable role, a resource policy naming the other account, a shared VPC via RAM). This is stronger than a Kubernetes namespace and closer to *a whole separate cluster that also has its own bank account and its own API rate limits*. It's the blast-radius container: the reason full multi-account (stretch X4) is a real security control is that an account compromise is bounded.
- **Organization:** a group of accounts under one **management (payer) account**, with consolidated billing and optional org-wide guardrails: **SCPs** (Service Control Policies, a ceiling on what principals *can be allowed* to do) and **RCPs** (Resource Control Policies, a ceiling on what resource policies *can allow*, launched late 2024). You have this: `mora-management` (payer) + `mora-dev` (workload).
- **Region:** an independent, near-complete copy of AWS. `us-east-2` is Ohio. Services in one region don't automatically know about another; data doesn't leave a region unless you move it. A handful of things are **global or pinned to `us-east-1`**, worth calling out because they cause real confusion:
  - **IAM** is global (a role exists account-wide, not per region) but its control plane lives in `us-east-1`.
  - **CloudFront** is global; its ACM certificate **must** be requested in `us-east-1` (spec S18 cert B).
  - **Billing/`EstimatedCharges`** CloudWatch metrics are only published in `us-east-1` (spec S03 billing alarm).
  - **Route 53** is a global service; **S3** bucket namespace is global though the data is regional; **STS** has both a global endpoint and regional endpoints (prefer regional).
- **Availability Zone (AZ):** a failure domain *inside* a region (`us-east-2a`, `2b`, `2c`): independent power, cooling, and network, but low-latency links between them. You spread across AZs so one failing halves capacity instead of killing you (game day GD5). Note AZ names are **shuffled per account** (`us-east-2a` in your account may be different physical hardware than in mine), a deliberate load-balancing trick that surprises people.

## The managed-service spectrum

AWS gives you the same capability at several levels of "how much do I operate," and choosing the level is a recurring design decision:

- **Unmanaged (EC2):** a VM. You own the OS, patching, scaling. Closest to your bare-metal nodes. This project deliberately avoids it (no EC2, no NAT) because managing VMs isn't the lesson.
- **Container-managed (ECS on Fargate):** you hand AWS a container + a task definition; it runs it, no nodes to manage. This is the query API (bills hourly → torn down each session).
- **Fully serverless (Lambda, SQS, SNS, DynamoDB, S3):** no capacity to think about, pay-per-use, scales to zero. This is the ingest path (cents/month → stays up 24/7).

The lesson this project keeps returning to is that the *billing shape* of a service (see `cost-and-teardown`) drives which level you pick more than performance does. Whenever you meet a new service, ask: which level of managed is this, and which side of the always-on/torn-down line does its billing put it on?

## Map to what you already know

Rough equivalences to your actual world: **the k8s you operate (k3s at home, a kubeadm microservices cluster at work), an external ActiveMQ broker and external nginx at work, and your Cisco / Packet-Tracer networking fundamentals** (which map to VPC/routing better than anything else). These are analogies, not identities; the "where it breaks" column is where the real learning is. Note the network rows below lean on **traditional routing/ACLs, not k8s CNI**, the mental model you actually have.

| AWS | Closest thing in your world | Where the analogy breaks |
|---|---|---|
| **Account** | A whole separate cluster that also owns its own billing + API quotas | Isolation is default-deny and total; nothing is shared across the line without explicit bridging |
| **Organization / SCP** | A fleet of clusters under one owner, with a policy that caps what any of them may do | SCPs only *subtract*; they never grant. They're a ceiling, not a Role |
| **IAM** | RBAC **+** admission control, but for *every* API call | Not just kube-apiserver but literally every service call; policies from 4+ sources combine in a fixed order |
| **IAM role** | A ServiceAccount (an identity a workload runs as) | Adds a **trust policy** (who may assume it) and hands out **temporary** STS creds |
| **Region / AZ** | Datacenter / rack failure domains | Regions are near-total independent copies of *everything*; AZ letters are shuffled per account |
| **VPC** | Your cluster's pod network, but off by default | You build subnets, route tables, gateways by hand; nothing routes until you say so |
| **Security group** | A **stateful ACL on an interface** (a Cisco reflexive / zone-based firewall rule) | Attaches per-ENI; stateful (return traffic auto-allowed); can *reference another SG by identity* instead of an IP/CIDR, which has no classic-networking analog |
| **Network ACL** | A **classic stateless router ACL** on a subnet | Stateless: you must permit return traffic explicitly; rarely needed here, SGs do most of the work |
| **SQS** | An **ActiveMQ** queue (your external broker at work) | Fully managed; no broker to run; **visibility timeout** instead of ack/nack sessions; at-least-once delivery |
| **SNS** | An ActiveMQ **topic** / fan-out exchange | Push pub/sub; for *durable* fan-out you pair it with SQS (SNS→SQS), unlike an in-broker topic subscription |
| **ECS / Fargate** | A Deployment / Pod, managed for you | task = pod, service = Deployment, task-def = pod spec; on Fargate there are **no nodes** to manage |
| **ALB** | Your **external nginx** reverse proxy / L7 LB (at work) | Managed and multi-AZ; **bills by the hour** whether traffic flows or not; integrates with target groups, not upstreams-in-a-file |
| **Lambda** | A Job / FaaS triggered by an event | No always-on process; **cold starts**; billed per-invocation-millisecond; concurrency is the scaling unit |
| **DynamoDB** | Cassandra (partition key + sort key) | Not an RDBMS: no ad-hoc joins or scans; you model tables around access patterns up front |
| **S3** | An object store (MinIO-shaped) | Also the substrate for Terraform state, logs, archives, and static site hosting |
| **CloudWatch** | Prometheus + Loki + Grafana + Alertmanager, bundled | One managed service billed per metric / log-GB / alarm; less flexible than Grafana, no server to run |
| **X-Ray / ADOT** | Tempo/Jaeger tracing you'd wire into Grafana | ADOT *is* OpenTelemetry; X-Ray is the managed backend/UI |
| **SSM Parameter Store** | Consul KV / a ConfigMap + Secret | Standard tier free; `SecureString` is KMS-encrypted; also the cross-layer wiring bus here |
| **Route 53** | Your authoritative DNS | **Alias** records point at AWS resources with no IP and no cost per query on the alias |
| **IAM Identity Center** | OIDC SSO that swaps you between kubeconfig contexts | Hands you a short-lived *assumed-role* session per account; requires an Organization |
| **CloudTrail** | The kube-apiserver audit log | Records control-plane API calls; can be org-wide to one bucket |
| **Terraform** | Terraform (you know the tool) | Same tool; the **state/backend** model and layer split are the new parts (see `terraform-layers-state`) |
| **Flux** | Flux (your GitOps reconciler) | No managed equivalent used here; Terraform + CI play the reconcile role, and *you* enforce drift discipline (G1) |

## The design philosophy that drives this project

**Two ingress paths, split by how they bill.** The webhook ingest is serverless (API Gateway → Lambda → SNS → SQS fan-out): effectively free, stays deployed 24/7. The query API is a container (internal ALB → ECS Fargate): bills hourly, so it's torn down after each session. This split is the spec's central lesson because in real shops, "what can stay up for near-zero" versus "what bills every hour" shapes architecture more than anyone admits. It drives the layer boundaries, the teardown reflex, and even which failure modes you'll actually practice. Whenever you meet a new service, ask which side of that line it's on (the `cost-and-teardown` page makes this concrete).

## The mental shifts that bite people from your background

1. **"It can't connect" is usually IAM, a security group, or a missing VPC endpoint, rarely DNS.** In k8s you assume a flat network and reach for DNS/service-discovery debugging. Here the network is locked down *on purpose*: this project has zero `0.0.0.0/0` egress and no NAT, so a component reaching an AWS API needs an exact VPC endpoint. A hang is almost always a missing network path or a missing permission, and that's by design: every such failure is a scripted lesson (VPC-endpoint and egress faults fail *loudly*, which is the point).
2. **Nothing trusts anything by default.** A Lambda cannot write to a queue, read a parameter, or publish to a topic until *its role grants it* **and** the *target resource's policy doesn't deny it*. You grant these one call at a time, building up from `AccessDenied`. This is least privilege as a daily habit, not a security review (its own page).
3. **Idle costs money.** Homelab hardware is a sunk cost, so leaving things running is free and you never had to build a FinOps reflex. Here an ALB you forgot bills every hour, and a stray interface endpoint bills silently. The teardown-and-verify-zero reflex is a real, transferable skill.
4. **There is no `kubectl exec` into most things.** No SSH to a Lambda, no node to inspect. Your observability *is* your debugging surface: CloudWatch Logs, metrics, CloudTrail, VPC Flow Logs. This is why the spec front-loads observability discipline: when you can't get a shell, you debug from telemetry, and building that telemetry is half the project.
5. **Quotas are real and per-account-per-region.** Concurrency limits, ENI limits, API rate limits: these exist and you'll hit them (deliberately, e.g. reserved concurrency on ingest). In k8s you tune your own limits; here AWS sets defaults and you request increases.

## Primary sources

- **AWS Well-Architected Framework**, especially the Reliability and Cost Optimization pillars. Read before the VPC/ECS block, not after.
- **The Amazon Builders' Library**, for the control-plane/data-plane and consistency mental models (the "static stability" and "avoiding fallback" articles are gold).
- The per-service **FAQ pages** (e.g. "Amazon SQS FAQs"): unusually good for the one-paragraph "what is this *really*" answer.
