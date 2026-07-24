# Decision: cross-layer state wiring (SSM vs remote_state)

**Spec ref:** S05.6 · **ADR:** yours to write · **Decided by spec as default:** SSM parameters, but you must be able to defend it.

## The decision

Layer 30 needs values layer 20 created (VPC ID, subnet IDs, SG IDs, the ACM cert ARN). How does a consumer layer read a producer layer's outputs across a state boundary? This recurs everywhere the layers touch, so the choice is structural, not incidental.

## Options

| Option | How it works | Cost |
|---|---|---|
| **`terraform_remote_state`** | Consumer reads the producer's *entire* state file directly | Simplest wiring, but grants read of **everything** in that state (including any sensitive attribute), and couples the consumer to the producer's internal resource structure |
| **Plain `data` sources** | Consumer looks resources up live by tag/name | No published contract; relies on stable naming; a live API lookup every plan; brittle if names drift |
| **SSM parameters (spec default)** | Producer *writes* the specific values to `/lf/dev/tf/<layer>/<name>`; consumer reads just those via `data "aws_ssm_parameter"` | You publish an explicit, minimal **interface** between layers; a little more wiring per output |

## Why the spec leans SSM

The cross-layer value set is **small and well-defined** (a handful of IDs and ARNs). When the shared surface is small, publishing it explicitly as parameters is a *tighter* design than exposing the whole state file: the consumer sees exactly the contract, nothing more, which is the least-privilege story (`terraform_remote_state` read access is all-or-nothing over the producer's state). It also decouples layers: you can refactor 20's internals freely as long as the published parameters stay stable.

## The alternative worth naming in the ADR

`terraform_remote_state` **guarded by a dedicated read-only state IAM role**. If you preferred remote_state's simplicity, you'd mitigate the blast radius with a role that can only read that one state prefix. Weigh it: it recovers some least privilege but adds an IAM role to manage and still couples to internal structure.

## Failure mode this choice creates (know it cold)

Destroy layer 20 and its published SSM parameters vanish, so layer 30 can no longer `plan` (its `data` lookups fail). This is **correct** (you shouldn't plan compute when its network is gone) but it makes ordering load-bearing: `up` = 20 then 30, `down` = 30 then 20. See `concepts/terraform-layers-state.md`.

## My lean

**SSM**, as the spec defaults. The small, explicit interface is the right call here and the least-privilege reasoning is genuinely stronger. The honest counter to record: at 3 layers and a dozen values, remote_state would also be *fine*, and SSM's per-output write is boilerplate. Decide which property you value (explicit interface and tight read scope, versus less wiring) and say so.

## Interview angle

"How do you share outputs across Terraform states, and what are the security implications?" is a common staff-level question. The crisp answer (remote_state reads the whole state, which is blast radius; parameter-published outputs are a minimal contract) is exactly what this ADR rehearses.

## Write the ADR

Record: the three options, why SSM over remote_state *for this project's small cross-layer surface*, the ordering failure mode you accept, and the read-only-role alternative you rejected and why.

## Primary sources

- Terraform `terraform_remote_state` data source docs (note the "exposes all outputs" caveat).
- AWS SSM Parameter Store docs; `data "aws_ssm_parameter"`.
