# Decision: CloudFront distribution layer (30 vs 10)

**Spec ref:** S22.3 · **ADR:** yours to write · **Spec default:** layer 30, but explicitly invites moving it.

## The decision

The status-page CloudFront distribution defaults to **layer 30** (torn down each session). But CloudFront distributions take **~5 minutes to create and ~5 minutes to delete**, so keeping it in 30 makes every `just up`/`just down` noticeably slower. Moving it to **layer 10** (always-on) is defensible.

## The tension

This is teardown-discipline (G3) meeting a slow-to-provision resource:

- CloudFront in **layer 30** is *ideologically* clean: it's part of the session-only compute/edge stack, dies with `just down`, nothing left running.
- But CloudFront costs **≈ $0 at zero traffic** (PriceClass_100, cache mostly idle between sessions), so leaving it up doesn't meaningfully spend money, unlike the ALB or the interface endpoints, which is *why* those must die.

So the resource fails the usual "does it bill hourly?" test that puts things in the teardown layer. It's cheap-when-idle, which is the signature of an always-on-layer resident.

## Options

| Option | For | Against |
|---|---|---|
| **Layer 30 (default)** | Ideologically consistent (all edge/compute in the session layer); nothing lingers | Adds ~10 min of create+delete to every session's up/down for a resource that isn't costing you anything |
| **Layer 10 (always-on)** | Fast `just up`/`down`; matches the "≈$0 idle → stays up" rule the rest of the serverless layer follows; the status page can even stay reachable between sessions | The status page points at an ALB/API that's *down* between sessions, so it'd show "unhealthy," which is arguably fine (it *is* down) or arguably confusing |

## The dependency wrinkle to check

The status bucket (`lf-status`) is already in layer 10; only the *distribution* is the question (S09 splits them: bucket in 10, distribution in 30 by default). CloudFront needs **cert B** (us-east-1, currently layer 30). If you move the distribution to 10, cert B moves with it, which means another us-east-1 provider alias in layer 10. Note that in the ADR; it's a small ripple, not a blocker.

## My lean

**Move it to layer 10.** It matches the project's own rule (*cheap-when-idle lives in the always-on layer*) and removes ~10 minutes of dead time from every single session, which compounds over the life of the project. The "it should die with the compute" instinct is aesthetic, not economic, and the economics say 10. The clean counter to record: keeping it in 30 means the entire *user-facing edge* is reproduced by `just up`, which is a nice end-to-end rebuild demonstration for the DR story. Decide which you value: session speed or rebuild completeness.

## Interview angle

"How do you decide which layer/lifecycle a resource belongs to?" The mature answer isn't "group by function." It's "group by *billing shape and provisioning latency*." A cheap, slow-to-create resource is a poor fit for a frequently-destroyed layer. That's the reusable heuristic.

## Write the ADR

Record: the ~5-min create/delete latency, the ≈$0-idle cost, the cert-B ripple if you move it, your choice and the heuristic behind it (billing shape and provisioning latency versus ideological grouping).

## Primary sources

- CloudFront docs (Origin Access Control, S22.1, and distribution deploy times).
- `concepts/cost-and-teardown.md` (the billing-shape → layer heuristic this decision applies).
