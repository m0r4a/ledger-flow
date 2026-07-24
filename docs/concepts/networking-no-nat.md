# Networking: a VPC with no NAT and zero open egress

This is the part of the project engineered to *fail loudly on purpose*. The design gives every private workload **no route to the internet at all** (no NAT gateway, no NAT instance, no `0.0.0.0/0` egress) and instead reaches AWS APIs through **VPC endpoints** that must be present and exactly configured. When something can't connect, it's almost always a missing endpoint or a security-group rule, and that failure *is* the lesson (S16.3's ECR-pull debugging is called out as "a core deliverable of this project"). Your k8s intuition of a flat pod network is exactly the instinct to unlearn here.

## VPC, subnets, CIDR: the address plan

- A **VPC** is your private network in one region: a CIDR block you own (`10.20.0.0/16`), inside which nothing routes to anything until you build routes. It is *off by default*, the opposite of a k8s cluster's flat pod network.
- **Subnets** are per-AZ slices of that CIDR. This project has four: `lf-public-a/b` (`10.20.0.0/20`, `10.20.16.0/20`) and `lf-private-a/b` (`10.20.128.0/20`, `10.20.144.0/20`), split across `us-east-2a`/`2b`. A subnet lives in exactly one AZ; that's how you get multi-AZ: put a copy of each tier in each AZ.
- **"Public" vs "private" is defined entirely by routing**, not a flag. A public subnet is one whose route table has a default route to an internet gateway; a private subnet is one whose route table *doesn't*. `map_public_ip_on_launch` is true on public, false on private, but the routing is what actually makes the distinction real.

**Map to your world:** this is the **Cisco / Packet-Tracer model**, not the k8s one: you're subnetting an address block and building the routing yourself. Subnets are subnets, route tables are router routing tables, the internet gateway is the edge router to the outside, and a private route table with **no default route is a router with no `ip route 0.0.0.0/0`**, a deliberate dead end. Nothing crosses between subnets until a route says so, exactly as on a router you've configured by hand.

## Route tables and the deliberate dead-end

- The **public route table** has `0.0.0.0/0 → internet gateway (IGW)`. Only the public subnets use it. In this project the public subnets exist mainly to hold the internal ALB and (conceptually) anything that must face the IGW, but note the ALB is **internal**, so even "public" here is tightly scoped.
- The **private route tables** (one per AZ) have **no default route at all.** Local VPC traffic works; everything else is a dead end until VPC endpoints add specific routes. This is the single most important, most counterintuitive line in the whole network design (S15.4: "No NAT Gateway, no NAT instance, nowhere, ever").
- The Verify (S15.6): a private route table should show *exactly* `local` + the two gateway-endpoint prefix-list routes after S16, nothing else. If you see a `0.0.0.0/0` there, something is wrong (or someone added NAT).

## Why no NAT: cost *and* pedagogy

A NAT gateway is the usual way private subnets reach the internet (for package installs, external API calls, pulling images from public registries). It's deliberately banned here for two reasons:

1. **Cost.** NAT bills ~$0.045/hr **plus ~$0.045 per GB processed**; the per-GB part is the classic surprise bill (see `cost-and-teardown`). A chatty workload behind NAT bleeds money continuously.
2. **Pedagogy.** With no NAT and no open egress, every AWS API call a workload makes *must* go through a VPC endpoint you built correctly. A missing or misconfigured endpoint produces a **hang or a clean failure**, which forces you to learn precisely how the workload reaches each service. In a NAT world it would "just work" and teach you nothing.

The consequence you must internalize: **your containers cannot `apt install`, cannot pull from Docker Hub, cannot call a random third-party API.** Images come from ECR *via endpoints*; secrets come from SSM *via endpoints*; logs go to CloudWatch *via endpoints*. If a design needs the public internet, that's a design smell to question, not a NAT to add.

## VPC endpoints: the two types, and why the split matters

Endpoints are how a locked-down VPC talks to AWS service APIs privately. There are two kinds, and the difference is both architectural and financial:

- **Gateway endpoints** (S3, DynamoDB only): a **route-table entry** pointing a service's prefix list at the endpoint. **Free.** No ENI, no hourly charge. This project attaches S3 and DynamoDB gateway endpoints to both private route tables (S16). Because they're free, there's no reason not to have them.
- **Interface endpoints** (everything else: `ecr.api`, `ecr.dkr`, `logs`, `sqs`, `ssm`, `ssmmessages`): an **ENI with a private IP** placed in each private subnet, fronted by AWS PrivateLink. **Bills ~$0.01/hr each** (plus per-GB). Six of them ≈ $0.06/hr, the **main hourly cost of layer 20**, which is exactly why S16 lives in the torn-down layer.

That gateway-free/interface-paid split is why the endpoints are the layer's cost driver and why `just down` kills them. Know which services get which type; it's a common interview question and a direct Verify here.

## private_dns_enabled: the magic that makes it transparent

Each interface endpoint sets `private_dns_enabled = true`, which makes the service's *normal* DNS name (`sqs.us-east-2.amazonaws.com`) resolve to the **endpoint's private IP** inside your VPC. That's why your code calls AWS SDKs with no special configuration and it "just works" privately: the SDK uses the standard endpoint, DNS quietly points it at the ENI. For this to function, the VPC needs **both** `enableDnsSupport` and `enableDnsHostnames` on (S15.1). If private DNS is off or the VPC DNS flags are wrong, the SDK resolves the *public* endpoint, tries to reach it with no internet route, and **hangs**, a signature failure mode of this design.

## The ECR-pull debugging exercise (S16.3, a core deliverable)

Pulling one container image from ECR into a Fargate task in a private subnet exercises **three** endpoints at once, and understanding which serves which part is the whole point:

- **`ecr.api`** (interface): the ECR control-plane calls: auth token, "where is this image."
- **`ecr.dkr`** (interface): the Docker registry protocol: manifest and layer *requests*.
- **`s3` gateway:** the actual image **layer blobs**, which ECR stores in S3. *This is the one people forget*, because "I'm pulling from ECR, why do I need S3?" But the bytes live in S3.

If the pull **hangs**, exactly one of these three is missing or misconfigured, and the exercise is to reason from the symptom to the culprit (and write it up). Predict-before-test material: before you launch the task, predict which endpoint each stage of the pull uses. And S16.4's *negative* Verify is just as important: ECS Exec into the task, `curl -m 5 https://checkip.amazonaws.com`, and confirm it **fails**, proof there's genuinely no internet path.

## Security groups: stateful, and referenced by SG not CIDR

Security groups are per-ENI virtual firewalls. Two properties your ACL/firewall intuition should map onto, plus one AWS-specific habit the spec enforces:

- **Stateful.** Allow inbound 8080 and the *response* is automatically allowed back out; you don't write a return rule. (Contrast the rarely-used, stateless **Network ACL** at the subnet level.)
- **Default deny.** A new SG allows nothing inbound and (by default) all outbound, but this project **strips the default `0.0.0.0/0` egress** and writes explicit, narrow egress rules (S17.1). Zero `0.0.0.0/0` egress anywhere in layers 20/30 is a hard Verify.
- **Reference SGs, never CIDRs, for internal hops.** `lf-api-sg` allows 8080 *from `lf-alb-sg`*: the source is *the other security group*, not an IP range. This is more precise and survives IP changes. The chain is: ALB-SG → API-SG (8080) → VPCE-SG (443); the worker SG mirrors the API's egress; the endpoint SG (`lf-vpce-sg`) admits 443 only from the API and worker SGs. Every rule carries a `description` (S17.2).

**Map to your world:** a security group is a **stateful ACL on an interface**, like a Cisco reflexive / zone-based firewall rule where return traffic is permitted automatically (contrast a plain stateless router ACL, which is exactly what a Network ACL is here). The one thing with no classic-networking analog: an SG rule can name *another security group* as its source instead of an IP/CIDR, an **identity** match ("allow from whatever lives in the ALB's SG") rather than an address match, which is more precise and survives IP changes. The stripped egress is just a default-deny-outbound ACL you poke specific, named holes in.

## Flow logs: off, but ready

VPC **flow logs** record accepted/rejected connections per ENI. They're **off by default here for cost** (S15.5), with a commented Terraform block ready to enable to CloudWatch for a game day. When a connection mysteriously fails and SG reasoning isn't enough, flow logs are the "did the packet even arrive, and was it accepted or rejected" ground truth, your tcpdump-equivalent when there's no host to tcpdump on. Turning them on to diagnose a seeded fault is a realistic exercise.

## Failure modes to expect (most are by design)

- **A private-subnet workload hangs calling an AWS API** → missing interface endpoint, or `private_dns_enabled`/VPC DNS flags off, so it resolved the public endpoint with no route.
- **ECR pull hangs** → one of `ecr.api` / `ecr.dkr` / `s3-gateway` missing (the S16.3 exercise).
- **"It can't reach the other service"** → an SG rule missing, or written as a CIDR when it should reference the peer SG.
- **A `0.0.0.0/0` egress rule sneaks in** → fails the S17.3 Verify; it means something wanted the internet and you should ask *why* before allowing it.
- **Task in one AZ can't reach an endpoint** → interface endpoints are per-subnet ENIs; if a subnet lacks the endpoint, workloads there have no path (this is also the shape of the GD5 AZ-loss drill).

## Primary sources

- **VPC User Guide**: subnets/route-tables, and the **"VPC endpoints"** and **"gateway vs interface endpoints"** pages specifically.
- **AWS PrivateLink** docs for how interface endpoints + private DNS work.
- The **ECR** docs section on **VPC endpoints for ECR** (it explicitly lists the `ecr.api` + `ecr.dkr` + S3 requirement, the S16.3 answer key, but read it *after* you've tried to reason it out).
- Security-group docs on **stateful behavior** and **referencing other security groups**.
