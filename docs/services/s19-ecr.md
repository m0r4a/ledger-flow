# S19: ECR

**Layer:** 00-foundation · **Session:** 5 · **Concept:** `concepts/cost-and-teardown.md` · **Decision:** `decisions/image-base.md`

## Purpose
The private image registry for the two container services. Repos live in layer 00 so **images survive `just down`** (you don't want to rebuild+push every session).

## Requirements that carry hidden depth
- **`IMMUTABLE` tags (19.2):** a tag can't be overwritten. Combined with SHA-only tagging, this makes "which image is running" unambiguous and prevents a silent re-push under a reused tag.
- **Full 40-char git SHA tags only, no `latest`, ever (19.3):** not in CI, not "just to test." `latest` is mutable and untraceable; SHA tags tie a running task to an exact commit. This is a discipline the deploy contract (S21.12) depends on.
- **Multi-stage build → distroless or scratch (19.4, [you decide]):** `USER nonroot`, arm64, **< 25 MB**. The three static-Go gotchas (ca-certs, non-root user, tzdata) decide the base; see `decisions/image-base.md`. Trying scratch and feeling what breaks (TLS x509 error without ca-certs) is a worthwhile exercise.
- **Scan-on-push, lifecycle policy (19.2):** expire untagged after 7d, keep last 10 tagged. Prevents ECR storage creep.

## What the Verify is really testing
**19.5, `docker inspect` shows a non-root numeric UID; ECR scan shows zero CRITICAL findings.** It proves the image runs unprivileged and has a minimal attack surface. A CRITICAL finding or a root UID is a build to fix, not ship.

## Cross-links
- distroless vs scratch, the static-Go gotchas → `decisions/image-base.md`.
- ECR pull through endpoints → `services/s16-vpc-endpoints.md`.

## Done when
Repos exist in layer 00 with immutable SHA-only tags, scan-on-push, and lifecycle; images are non-root, arm64, < 25 MB, zero CRITICAL.
