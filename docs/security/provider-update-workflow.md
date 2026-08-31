# TLS provider security-update intake

M0-016 treats provider maintenance as evidence, not as an assumption. The
machine-readable provider pins in `tools/tls_provider_poc/providers.json` set a
maximum source-pin age of 180 days and bind the upstream commit timestamp.
`validate.py` fails closed when a pin exceeds that age.

Maintainers review these official advisory channels at least monthly and again
before a release candidate is approved:

- AWS-LC: [GitHub Security Advisories](https://github.com/aws/aws-lc/security/advisories)
- Mbed TLS: [official security advisories](https://mbed-tls.readthedocs.io/en/latest/security-advisories/)
- OpenSSL control: [official vulnerability list](https://openssl-library.org/news/vulnerabilities/)

For every advisory, record whether the pinned source is affected. A known
affected pin blocks promotion immediately, regardless of its age. Updating a
pin requires review of the source identity, license bundle, build provenance,
native capability results, sanitizer evidence, allocation profile and static
dependency scan. Old results remain stale until the complete affected matrix
is rerun.

This document defines M0-016 intake and freshness evidence. M7-015 owns the
release-response SLA, notification and downstream publication runbook.
