# Decision: ECS tracing (ADOT Collector sidecar vs OTel SDK in-process)

**Spec ref:** S24.4 · **ADR:** yours to write · **Fixed by spec:** use OpenTelemetry either way, export to X-Ray (the X-Ray SDK is in maintenance, don't use it); Lambdas use active tracing regardless.

## The decision

For the two ECS services (`ledger-api`, `fraud-worker`), how do spans get from your Go code to X-Ray? Two architectures:

- **ADOT Collector sidecar:** a second container (AWS Distro for OpenTelemetry Collector) runs in the task; your app exports OTLP to `localhost`, and the sidecar batches/translates and ships to X-Ray.
- **OTel SDK in-process:** your Go app links the OpenTelemetry SDK + an X-Ray exporter and ships spans itself, no extra container.

## Options

| | ADOT sidecar | OTel SDK in-process |
|---|---|---|
| **App code** | Thin: export OTLP to localhost; app doesn't know about X-Ray | App owns exporter config, batching, retries |
| **Task shape** | +1 container (more memory/CPU, a little cost), a container to configure and keep patched | Single container, simpler task def |
| **Separation of concerns** | Telemetry pipeline decoupled from app; swap backends by reconfiguring the collector, not redeploying code | Backend choice baked into the binary |
| **Batching/back-pressure** | Handled by the collector (purpose-built) | You rely on the SDK's batch processor |
| **Ops model** | The "standard" production pattern; scales to fleet-wide config | Fewer moving parts for a two-service project |
| **`readonlyRootFilesystem`** | Sidecar needs its own writable scratch handled | One container's filesystem to reason about |

## The real tradeoff

**Operational decoupling versus fewer moving parts.** The sidecar is the pattern you'd see in a real production fleet: the app emits vendor-neutral OTLP and the collector owns "where telemetry goes," so switching backends or adding sampling is a collector config change, not a rebuild. The in-process SDK is simpler for a small project (one container, no sidecar to size or patch) at the cost of baking the export path into the binary. Both send OTel spans to X-Ray; the trace quality is the same.

## The part that's hard regardless of which you pick

**Context propagation across SNS→SQS.** A trace is only end-to-end if the `traceparent` rides through the message: ingest must **inject** trace context into SNS message attributes, and the consumers (`fraud-worker`, etc.) must **extract** it and continue the trace as **span links** (async, so links rather than parent-child). This is identical work whether you use the sidecar or the SDK. The deliverable is one screenshot of API GW → ingest → fraud-worker → DynamoDB as a connected trace. Don't let the sidecar-vs-SDK choice distract from this; it's where traces actually break (see `concepts/observability-slo.md`).

## My lean

**ADOT sidecar.** It's the production-representative pattern and the more valuable thing to have built once: the decoupling ("app speaks OTLP, collector owns the backend") is a genuinely useful architecture to understand, and it's the answer that reads as "has run OTel in anger." The honest counter: for two services with modest needs, in-process is meaningfully less to operate and teaches OTel just as well. If your goal this pass is "get tracing working with minimal task complexity," start in-process and note the sidecar as the production evolution. Either way, budget your real effort for the SNS/SQS propagation.

## Interview angle

"How do you run OpenTelemetry in ECS, and why a collector?" The sidecar/collector rationale (decoupling, central pipeline config, batching/back-pressure offload) plus the honest "in-process is fine at small scale" is a complete answer. And "how do you keep a trace intact across a queue?" tests the propagation piece.

## Write the ADR

Record: both architectures, that both are OTel→X-Ray (X-Ray SDK rejected as maintenance-mode), your choice and why, and a separate note that `traceparent` propagation through SNS/SQS message attributes is required regardless.

## Primary sources

- **AWS Distro for OpenTelemetry (ADOT)** docs: the ECS sidecar collector setup and the X-Ray exporter.
- OpenTelemetry Go SDK docs (span processors, propagators).
- W3C **Trace Context** spec (`traceparent` header/format) and X-Ray trace context.
