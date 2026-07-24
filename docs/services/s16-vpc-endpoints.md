# S16: VPC endpoints

**Layer:** 20-network · **Session:** 5 · **Concept:** `concepts/networking-no-nat.md`

## Purpose
The *only* way anything in the private subnets reaches an AWS API. With no NAT, these endpoints are the network, and the flagship debugging exercise of the whole project lives here.

## Requirements that carry hidden depth
- **Gateway (free) vs interface (~$0.01/h each) (16):** S3 + DynamoDB are **gateway** endpoints (route-table entries, free). ecr.api, ecr.dkr, logs, sqs, ssm, ssmmessages are **interface** endpoints (ENIs via PrivateLink, hourly). The six interface endpoints ≈ the layer's main hourly cost, which is exactly why S16 lives in the torn-down layer 20.
- **`private_dns_enabled=true` on every interface endpoint (16.1):** makes the service's normal DNS name resolve to the endpoint's private IP, so SDKs "just work" with no config. Off → SDK resolves the public endpoint → hang (ties back to S15.1's DNS flags).
- **All of S16 is layer 20 → dies with `just down` (16.2):** the ~$0.06/h you don't want running overnight.

## What the Verify is really testing
- **16.3 (the core deliverable):** a Fargate task pulls an image from ECR, and you must explain **which of ecr.api / ecr.dkr / s3-gateway served which part** (control-plane auth / registry protocol / **the layer blobs, which live in S3**, the forgotten one). If it hangs, exactly one endpoint is missing/misconfigured. **Write this up**; it's the most "SRE" artifact so far. **Predict** which endpoint each pull stage uses before launching.
- **16.4 (negative Verify):** ECS Exec in, `curl -m 5 https://checkip.amazonaws.com` → **must fail**. Proving there's no internet path is an acceptance test. Predict the failure shape (hang-to-timeout vs immediate).

## Cross-links
- Gateway-vs-interface, private DNS, the ECR-pull three-endpoint reasoning → `concepts/networking-no-nat.md`.
- Why interface endpoints are the teardown cost → `concepts/cost-and-teardown.md`.

## Done when
Two gateway + six interface endpoints exist; the ECR pull works and you can explain it; the internet-egress `curl` fails; both predicted first.
