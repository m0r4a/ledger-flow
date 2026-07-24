# Decision: ingest Lambda reserved concurrency cap

**Spec ref:** S13.13 (also S14.3) · **ADR:** yours to write · **Spec instruction:** pick a number (e.g. 50), understand reserved vs provisioned, ADR the number.

## The decision

The `lf-ingest` Lambda gets a **reserved concurrency** cap (the spec suggests ~50). What number, and why, and do you understand what reserved concurrency actually does?

## Reserved vs provisioned: get this straight first (it's half the point)

Two different Lambda concurrency controls people constantly confuse:

- **Reserved concurrency:** a **cap** *and* a guarantee. It sets the *maximum* simultaneous executions this function can have, carved out of the account's pool. It's **free**. Setting ingest to 50 means: ingest can never exceed 50 concurrent (blast-radius/cost ceiling) *and* those 50 are reserved for it (no other function can starve it).
- **Provisioned concurrency:** **pre-warmed** execution environments to eliminate cold starts. It **bills hourly** (like keeping servers warm). You are **not** using this; it's the opposite trade (spend money to remove latency).

Confusing the two in an interview is a tell. The ADR should state the distinction in your own words.

## Why cap ingest at all

Ingest sits at the **front door** behind API Gateway. Without a cap, a runaway loadgen loop or a traffic spike could drive ingest to the **account default of 1000** concurrent executions, and each one publishes to SNS → fans out to every downstream queue → multiplies SQS/SNS/DynamoDB request costs and worker load. The cap is a **blast-radius and cost ceiling**: a bug upstream can't cascade into a bill or a downstream overload. It pairs with the **API Gateway throttle** (25 rps, burst 50, S14.3): two independent ceilings at two layers (see `concepts/cost-and-teardown.md`).

## Choosing the number

Reason from the two ceilings and the math:

- **The API GW throttle is 25 rps** (burst 50). Ingest is 128 MB, 5 s timeout, but in practice completes in tens of ms (HMAC verify + one SNS publish). By **Little's Law**, concurrency ≈ arrival-rate × service-time: 25 rps × ~0.05 s ≈ **~1.3 concurrent** in steady state; even a 50-burst against a 5 s worst-case timeout is ~50 concurrent only if every request stalled to timeout (it won't).
- So **50 is comfortably above real need** while still being far below 1000: headroom for bursts and slow-tail requests, but a hard stop well short of "fan out the whole account."
- Going **much lower** (e.g. 5) risks **throttling legitimate bursts** (ingest returns 429s, API GW surfaces 5xx), a self-inflicted availability hit. Going **higher** (e.g. 200) weakens the blast-radius ceiling for no real benefit at your traffic.

## My lean

**50, as the spec suggests.** It clears the Little's-Law steady-state need by a wide margin, absorbs the 50-burst, and still caps blast radius at 1/20th of the account default. If you want the cap to *bite* during a game day (to observe throttling behavior deliberately, R9.2), you might pick a lower number *for that drill* and document it, but 50 is the right standing value. The number matters less than showing the reasoning: derive it from the throttle + service time, don't pluck it.

## The game-day tie-in (R9.2)

S27's load test asks: at burst, do you hit the **Lambda concurrency cap** or the **API Gateway throttle** first? With ingest at 50 and API GW at 25 rps/50 burst, predict it *before* you test (predict-before-test applies). Reasoning: the API GW throttle (25 rps) should bite first for sustained load; the concurrency cap bites first only if service time spikes. Write the prediction, then find out.

## Interview angle

"Reserved vs provisioned concurrency?" and "how would you protect a downstream system from an upstream spike?" are both directly rehearsed here. The Little's-Law derivation of the number is the senior flourish.

## Write the ADR

Record: reserved-vs-provisioned in your words, why ingest specifically needs a cap (front door → fan-out), the Little's-Law-informed choice of 50, the interaction with the API GW throttle, and the R9.2 prediction.

## Primary sources

- Lambda docs: **reserved concurrency** vs **provisioned concurrency** (read both pages; the distinction is the point).
- API Gateway throttling docs (stage-level rate/burst).
- Little's Law (L = λW), the one-line queueing result behind the number.
