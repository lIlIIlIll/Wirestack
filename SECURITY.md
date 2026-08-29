# Security policy

Wirestack is under active development and has not completed its Linux stable
release security review or release-signing gate. Version `0.1.0` is not a
production security certification.

## Report a vulnerability

Do not open a public issue containing an exploit, private key, credential,
certificate secret, request body or other sensitive material. Use GitHub's
private vulnerability reporting for `lIlIIlIll/Wirestack` when available. If
that channel is unavailable, contact the repository owner privately.

Include the affected commit or artifact digest and platform, the public API or
protocol path, a minimal reproduction, expected and observed terminal states,
impact, and any workaround that does not weaken TLS. Do not send live
credentials or production traffic captures.

## Supported security profile

Current native evidence covers Linux x86_64 glibc with pinned AWS-LC 5.5.0.
Linux musl and the remaining platform matrix are not qualified. Provider
selection happens at build time; the default Linux artifact must not depend on
system OpenSSL.

The [threat model](docs/security/threat-model.md) defines P0 assets, boundaries
and release blockers. [Linux status](docs/planning/linux-status.md) records the
current security, fuzz, supply-chain and release gates.

## Release treatment

Any unresolved High or Critical finding blocks a stable release.
Cross-compilation, skipped tests, stale evidence and provider-only PoCs do not
close a platform security claim. M7-029 owns the independent Linux review;
M7-030 owns artifact, SBOM and manifest signing.
