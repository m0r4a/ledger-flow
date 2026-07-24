# S02: Account & IAM Identity Center

**Layer:** bootstrap + 00-foundation · **Session:** 1-2 · **Concept:** `concepts/identity-accounts-iam.md`

## Purpose
Secure both account roots, stand up workforce sign-in (Identity Center), and get a short-lived SSO CLI session. This is the identity foundation everything authenticates against.

## Requirements that carry hidden depth
- **Root MFA on *both* roots, zero access keys (2.1):** the **management root is the org crown jewel**; a compromise there owns both accounts. `AccountAccessKeysPresent: 0` in *each* account. The easy miss: hardening dev and forgetting management.
- **Identity Center *requires* an Organization (2.3):** enabling it **creates** the org if absent. This corrected a spec-era misconception; the org is mandatory, not optional. Full multi-account (SCPs, delegated admin) is stretch X4.
- **Bootstrap-by-console exception (2.3 senior note):** Identity Center is the one sanctioned **non-IaC** step (you can't Terraform the initial setup cleanly). Document the exact clicks in `docs/bootstrap.md` so the account stays reproducible by instructions (G1's escape hatch, used honestly).
- **Permission set `LedgerFlowAdmin`, 8h session (2.5):** `AdministratorAccess`, 8-hour duration. You are *always* an assumed role, never a static user (G4).
- **No `[default]` keys anywhere (2.6):** `~/.aws/credentials` holds no long-lived secret; auth is `aws sso login`.

## What the Verify is really testing
`aws sts get-caller-identity --profile lf-dev` → an `assumed-role/AWSReservedSSO_LedgerFlowAdmin...` ARN. It's proving you're authenticating via **temporary STS creds from SSO**, not a static key: the whole G4 posture in one command. Boolean → no prediction.

## Cross-links
- Why roles-not-users, trust-vs-permission, the SSO ARN shape → `concepts/identity-accounts-iam.md`.
- The two-account split and profiles (`lf-mgmt`/`lf-dev`) → `sessions/session-02.md`.

## Done when
Both roots MFA'd with zero keys; Identity Center live; `lf-dev` (and `lf-mgmt`) SSO profiles return assumed-role ARNs; bootstrap steps documented.
