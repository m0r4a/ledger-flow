# Decision: container base image (distroless/static vs scratch)

**Spec ref:** S19.4 · **ADR:** yours to write · **Constraints fixed by spec:** multi-stage build, `USER nonroot`, `linux/arm64`, final image < 25 MB, zero CRITICAL scan findings.

## The decision

Your Go services compile to a static binary. The final stage of the multi-stage Dockerfile can be one of two near-empty bases: **`gcr.io/distroless/static`** or **`scratch`** (plus whatever you add yourself).

## Options

| | `gcr.io/distroless/static` | `scratch` |
|---|---|---|
| **What you get** | A minimal base that *already includes* CA certificates, `/etc/passwd` with a `nonroot` user, tzdata, and `/tmp` | Literally nothing, an empty filesystem |
| **CA certs (for TLS to AWS)** | Included | **You must add `ca-certificates` yourself** or every HTTPS call fails |
| **Non-root user** | `nonroot` user (UID 65532) provided; `USER nonroot` just works | No `/etc/passwd`; you must create the user entry or run by numeric UID |
| **Timezone data** | Included | Add `tzdata` if you format times in non-UTC (you use RFC3339 UTC, so maybe not) |
| **Image size** | Tiny (~2 MB base) | Tinier (0) |
| **Provenance** | Google-maintained, regularly rebuilt/patched | You own every byte |

## The real tradeoff

This is **convenience and safe defaults versus absolute minimalism and total control.** With Go static binaries the practical gotchas are always the same three: **CA certs** (needed for TLS to every AWS API; miss this and you get `x509: certificate signed by unknown authority`), a **non-root user** entry, and maybe **tzdata**. Distroless hands you all three; scratch makes you provide exactly what you need and nothing more.

Both easily clear < 25 MB and can hit zero CRITICALs (fewer files means a smaller attack surface, which *helps* the scan). So the decision is about which failure modes you'd rather own.

## My lean

**`distroless/static`** for a first real build: the CA-certs and non-root defaults remove the two most common "works locally, breaks in Fargate" surprises, and it's still tiny. Then, as a *deliberate learning exercise*, try `scratch` and feel exactly what breaks (TLS fails without ca-certs; `USER nonroot` fails without the passwd entry). That failure is genuinely instructive and worth doing once. The scratch counter-argument is real for a security-max posture: you audit every byte and depend on no external base. Record which you value.

## Failure modes to name in the ADR

- **scratch without ca-certs** → all HTTPS to AWS fails with an x509 error. The #1 scratch gotcha.
- **scratch with `USER nonroot`** but no `/etc/passwd` entry → the user can't resolve; run by numeric UID or add the entry.
- Either base with a **`readonlyRootFilesystem` task** (S21.5/21.6) → anything writing to disk must use a mounted `/tmp` or in-memory; a good thing to discover now.

## Interview angle

"Why distroless/scratch, and what do you have to add for a Go service to make TLS work?" The ca-certs answer signals you've actually shipped minimal containers, not just read about them.

## Write the ADR

Record: the two bases, the three static-Go gotchas (certs/user/tz), your choice and why, and (if you go distroless) a note that you tried scratch and what broke.

## Primary sources

- GoogleContainerTools **distroless** repo README (the `static` image contents).
- Go docs on `CGO_ENABLED=0` static builds; the `crypto/x509` system-roots behavior.
- ECR image scanning docs (S19.5 zero-CRITICAL gate).
