# S15: VPC & subnets

**Layer:** 20-network · **Session:** 5 · **Concept:** `concepts/networking-no-nat.md`

## Purpose
The private network, built by hand on the Cisco/routing model, with a deliberate dead end where the internet would be.

## Requirements that carry hidden depth
- **DNS support + DNS hostnames both on (15.1):** the interface endpoints' private DNS needs **both**. Forget one and SDK calls resolve the *public* endpoint, find no route, and **hang**. This one flag pair is behind a huge share of "why does it hang" incidents here.
- **Private route tables have NO default route (15.4):** a router with no `ip route 0.0.0.0/0`. No NAT gateway, no NAT instance, nowhere, ever. This is the single most counterintuitive line in the network and the source of every "designed to fail loudly" lesson.
- **Public vs private is defined by routing, not a flag (15.2/15.3):** public subnets route `0.0.0.0/0 → IGW`; private ones don't. `map_public_ip_on_launch` follows but the route table is what makes it real.
- **Flow logs off, block ready (15.5):** cost; a commented block enables them to CloudWatch for a game day (your "tcpdump when there's no host" for a stubborn connection failure).

## What the Verify is really testing
**15.6, `just status` prints `NAT gateways: 0`; a private route table shows *exactly* `local` + the two gateway-endpoint routes (after S16).** It proves the dead end is real and nothing snuck a default route in. A `0.0.0.0/0` in a private RT is an immediate red flag.

## Cross-links
- The whole no-NAT model, Cisco mapping → `concepts/networking-no-nat.md`.
- Why NAT is banned (cost + pedagogy) → `concepts/cost-and-teardown.md`.

## Done when
VPC with DNS flags on, four subnets across two AZs, public RT → IGW, private RTs with no default route; `just status` shows zero NAT.
