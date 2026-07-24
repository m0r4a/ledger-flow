# Observability: metrics, SLOs, burn-rate alarms & tracing

Because there's no node to SSH into and no `kubectl logs`, **your telemetry is your entire debugging surface**, and building it well is half the project. You know the shapes from Prometheus + Loki + Grafana + Alertmanager + Tempo; CloudWatch bundles all of that into one managed (and separately-billed) service, and the discipline here is to instrument deliberately, alarm on *symptoms users feel*, and keep it cheap. The whole observability half culminates in one proof (S24.5): revoke a permission, watch the right alarm fire, and trace the email back to the IAM change.

## The four telemetry types and their CloudWatch homes

- **Logs** → CloudWatch **Logs** (log groups, e.g. `/aws/lambda/lf-ingest`, `/lf/ecs/ledger-api`), all Terraform-managed with **14-day retention** so storage doesn't creep. Query them with **Logs Insights**.
- **Metrics** → CloudWatch **Metrics**, namespaced (`LedgerFlow`), emitted via **EMF** (below).
- **Alarms** → CloudWatch **Alarms**, all routed to the `lf-alerts` SNS topic → your email.
- **Traces** → **X-Ray** (via OpenTelemetry/ADOT), the request-flow view.

**Map to your world:** Logs ≈ Loki, Metrics ≈ Prometheus, Alarms ≈ Alertmanager, Dashboard ≈ Grafana, Traces ≈ Tempo/Jaeger. The big differences: it's managed (no server to run), less flexible than Grafana/PromQL, and **billed per metric / per GB of logs / per alarm**, so restraint is a design constraint, not a preference.

## EMF: structured metrics without a metrics API call

**Embedded Metric Format** is the key technique. Instead of calling `PutMetricData` synchronously (which costs per call and adds latency in a hot path), your code writes a **specially-structured JSON log line**; CloudWatch parses it and *extracts the metrics asynchronously* from the log. You get metrics "for free" alongside logs you were already writing, with no blocking API call.

- The spec **mandates EMF and bans `PutMetricData` in hot paths** (S24): a real cost-and-latency decision.
- **Cardinality is the cost lever.** Each unique metric × dimension-value combination is a separate **metric stream** billed ~$0.30/mo. A dimension like `eventType` (a few values) is fine; a dimension like `customerId` (thousands) would explode into thousands of streams. The spec keeps total custom streams **< 10** and chooses dimensions accordingly (`EventsRejected` by `reason`, `EventsIngested` by `eventType`, most others dimensionless). When you add a metric, count its cardinality first.

**Map to your world:** EMF is close to writing structured logs that a Loki/Promtail pipeline turns into metrics, except CloudWatch does the extraction natively. Cardinality discipline is the same lesson as "don't put unbounded labels on a Prometheus metric."

## SLIs, SLOs, and error budgets: the actual method

The spec (S24.3) makes you write `docs/slos.md` and **do the error-budget arithmetic by hand once**, because the arithmetic is the understanding. The vocabulary:

- **SLI (Indicator):** a *measured* ratio of good events to total, e.g. "canary requests that succeeded / total canary requests." It must map to a real metric you emit.
- **SLO (Objective):** the target for that SLI over a window, e.g. **ingest availability 99.5% / 30 days** (SLI = canary success rate); **ingest p99 < 500 ms**; **event→ledger p95 < 60 s**.
- **Error budget:** the allowed failure: `100% − SLO`. At 99.5%/30d that's **0.5% of 30 days ≈ 3h 39m** of allowed "bad" per month. This is the number that turns reliability from vibes into arithmetic: you can *spend* the budget on risk, and when it's exhausted you stop shipping and fix.

Do the sum yourself: 30 days = 43,200 minutes; 0.5% = 216 minutes ≈ 3.6 hours. That single hand-calculation is what S24.3 is really testing.

## Burn-rate alarms: alert on symptoms, at two speeds

The naïve alarm ("error rate > 0") pages you constantly and teaches you to ignore it. The SRE-Workbook approach the spec adopts is **multi-window burn-rate**: alert on how *fast* you're consuming the error budget, at two sensitivities (S24, `lf-ingest-errors-fast`/`-slow`):

- **Fast burn:** error ratio **> 5% over 5 min**: something is badly broken *right now*, page immediately (you'd blow a big chunk of budget fast).
- **Slow burn:** error ratio **> 1% over 1 h**: a low-grade problem that will exhaust the budget over time; ticket it, don't wake anyone.

The point is to page on *user-facing symptom severity*, not on every blip: the difference between an alert you trust and alert fatigue. These use **metric math** over Lambda `Errors`/`Invocations`.

## The alarm catalog, grouped by what it protects

The S24 alarms aren't arbitrary; each maps to a failure a user or the budget would feel:

- **Backpressure / loss:** DLQ depth ≥ 1 (`lf-dlq-*`: a message failed all retries), fraud-queue oldest-message age > 300s (`lf-fraud-backlog-age`: a consumer is falling behind or down).
- **Error rate:** the fast/slow burn pair on ingest; Lambda `Throttles` ≥ 1 (you hit a concurrency ceiling).
- **User-facing latency/errors:** ALB 5xx ≥ 5 in 5 min, ALB p99 > 0.5s.
- **Correctness:** `ReconciliationDrift` > 0 (the ledger disagrees with itself, the one that means "money is wrong").
- **The watcher itself:** `lf-canary-fail` (synthetic probe failing), with `treat_missing_data = breaching` so *silence* counts as failure, not success.

That `treat_missing_data` choice is a classic subtlety worth internalizing: for a liveness signal, **missing data must mean "broken," not "fine"**, otherwise a dead canary looks healthy.

## Synthetic monitoring: the canary

The **canary** Lambda periodically sends a real signed webhook and checks it flows through, emitting `CanaryIngestOk` (0/1) and `CanaryIngestLatencyMs`. This is **synthetic monitoring**: you measure availability from the *user's* perspective continuously, instead of inferring health from internal metrics. It's also the SLI source for the ingest-availability SLO: the canary success rate *is* the availability number. (This is why the canary failing, or going silent, is treated as breaching.)

## Distributed tracing: OTel → X-Ray, and context across the queue

Tracing answers "where did this one request spend its time, across services." The spec's stance (S24.4):

- **Use OpenTelemetry either way:** the older X-Ray SDK is in maintenance. The `[you decide]` is **ADOT Collector sidecar** vs **OTel SDK in-process** on the two ECS services (dossier: `decisions/tracing.md`); Lambdas use **active tracing**. Both export to **X-Ray** as the backend/UI.
- **The hard part is context propagation across async hops.** A trace is a tree of spans linked by a trace ID. HTTP carries it in a `traceparent` header automatically, but **SNS→SQS is a message boundary**: the context must be **carried in message attributes** and **re-attached in the consumer** (as span *links*, since it's async, not a direct parent-child call). Get this wrong and your trace "ends" at the publish and a disconnected trace "starts" at the consumer. The deliverable is one end-to-end trace screenshot: API GW → ingest → fraud-worker → DynamoDB.

**Map to your world:** OTel/ADOT is the same OpenTelemetry you'd wire into Tempo; X-Ray is just the managed backend. Propagating `traceparent` through SNS/SQS message attributes is the exact problem you'd have propagating trace context across an ActiveMQ hop: the broker doesn't carry it for you.

## The L1/L2/L3 dashboard model

The `lf-overview` dashboard (S24.1) is deliberately layered so it answers questions in escalating depth, the same instinct as a good Grafana dashboard hierarchy:

- **L1, is the service healthy for users?** EventsIngested rate, CanaryIngestOk, ProcessingLatency p95, error-rate %. The "should I care right now" row.
- **L2, where is the problem?** Per-queue depth+age, running task counts, Lambda duration p95+errors, ALB p99. The "which component" row.
- **L3, dig in.** Saved Logs Insights queries, `EstimatedCharges`. The "drop to raw evidence" row.

Three **Logs Insights** queries are saved *and committed to runbooks* (S24.2): find an event by `providerEventId` across all groups; ingest rejects by reason over time; fraud-worker errors ±5 min around a timestamp. Committing them means the debugging path is reproducible, not re-invented under pressure.

## The capstone Verify (S24.5): observability proving itself

Revoke the fraud-worker's `dynamodb:PutItem` with a one-line Terraform change. Predict first (behavioral, so predict-before-test applies): **which** alarm fires and **how fast**. Expected: `lf-fraud-backlog-age` fires in < 10 min (the worker now fails every write, messages stop being deleted, the queue's oldest-message age climbs past 300s). Then the runbook `docs/runbooks/backlog-growing.md` must lead from that email → CloudTrail/IAM root cause. This is the whole observability thesis in one exercise: a real failure, caught by a symptom alarm, traced to its cause through your telemetry.

## Failure modes to expect

- **Metric cardinality explosion** → a high-cardinality dimension turned one metric into thousands of billed streams. Count cardinality before adding a dimension.
- **Alarm fatigue** → alarming on raw error counts instead of burn rate; nobody trusts the pages.
- **Dead canary reads as healthy** → `treat_missing_data` not set to `breaching` on a liveness signal.
- **Trace ends at the queue** → `traceparent` not propagated through SNS/SQS message attributes.
- **Logs bill spikes** → a debug-logging spree in a hot Lambda; logs bill on GB ingested (see `cost-and-teardown`).
- **Retention creep** → a log group created outside Terraform keeps logs forever at the default.

## Primary sources

- **The Google SRE Book & SRE Workbook**: the SLI/SLO/error-budget chapters and especially **"Alerting on SLOs"** (the multi-window burn-rate method the alarms implement). This is the canonical read; do it before writing `slos.md`.
- **CloudWatch** docs: **Embedded Metric Format**, **metric math**, **composite alarms**, and **`treat_missing_data`** semantics.
- **CloudWatch Logs Insights** query syntax.
- **AWS Distro for OpenTelemetry (ADOT)** docs and the **X-Ray** trace-context/propagation guide; the W3C **`traceparent`** spec for the header format.
