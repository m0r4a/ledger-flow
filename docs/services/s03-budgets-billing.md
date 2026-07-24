# S03: Budgets & billing alarms

**Layer:** 00-org (management account) · **Session:** 2 · **Concept:** `concepts/cost-and-teardown.md`

## Purpose
The two-mechanism money guardrail (G2). This is what lets you build hourly-billed things without fear: the meter is watched two independent ways.

## Requirements that carry hidden depth
- **Everything here lives in the *management* account (3.1/3.3/3.4):** consolidated billing surfaces `EstimatedCharges` only in the payer account; member-account charges roll up there. This is the first real `lf-mgmt`-profile work.
- **The alarm + its topic are in *us-east-1* (3.3/3.4):** the billing metric is published only there, while everything else is us-east-2. First encounter with the us-east-1 exception list; forgetting it means the alarm watches a metric that doesn't exist.
- **"Receive Billing Alerts" must be enabled in account prefs first (3.4):** console-only, one checkbox, in management. The `EstimatedCharges` metric **doesn't exist until you do it**, so the alarm has nothing to watch. A documented bootstrap exception.
- **Two mechanisms on purpose (3.1 + 3.4):** AWS Budgets (accounting view, 50/80/100% + forecast) *and* a CloudWatch alarm (metrics view). One can silently break; two rarely fail together.
- **Confirm the SNS email subscription.** An unconfirmed subscription drops every alert silently; the alarm "works" and you never get mail.

## What the Verify is really testing
**3.5, test it:** temporarily set a $1 budget, receive the email, delete it. The point: *an untested alert doesn't exist.* **Predict-before-test:** before the test, write down how long until the email arrives and what triggers it (actual vs forecast; budget vs alarm first). Billing metrics update on a lag; commit to a number.

## Cross-links
- Billing shapes, why this matters, the CloudWatch cost traps → `concepts/cost-and-teardown.md`.
- Why management + us-east-1 → `concepts/identity-accounts-iam.md` (two-account split), `sessions/session-02.md`.

## Done when
Both mechanisms live in management/us-east-1, email subscription confirmed, and the mechanism **tested** with a prediction logged.
