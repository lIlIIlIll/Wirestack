# TLS provider security-update intake

M0-016 treats provider maintenance as evidence, not as an assumption. The
machine-readable provider pins in `tools/tls_provider_poc/providers.json` set a
maximum source-pin age of 180 days and bind the upstream commit timestamp.
`validate.py` fails closed when a pin exceeds that age.

Each pin also contains an `advisory_disposition` with the exact reviewed pin,
the `reviewed_through` timestamp, sorted unique advisory IDs, the affected
subset, and an `affected` or `not-affected` status. The disposition expires
after 31 days. A successful native result must retain the exact same
`security_update` object, so old results become stale when the review changes.

Maintainers review these official advisory channels at least monthly and again
before a release candidate is approved:

- AWS-LC: [GitHub Security Advisories](https://github.com/aws/aws-lc/security/advisories)
- Mbed TLS: [official security advisories](https://mbed-tls.readthedocs.io/en/latest/security-advisories/)
- OpenSSL control: [official vulnerability list](https://openssl-library.org/news/vulnerabilities/)

For every advisory, add its stable identifier to `reviewed_advisory_ids` and,
when applicable, to `affected_advisory_ids`. The status and affected subset
must agree. A known affected pin blocks promotion immediately, regardless of
its age. Updating a
pin requires review of the source identity, license bundle, build provenance,
native capability results, sanitizer evidence, allocation profile and static
dependency scan. Old results remain stale until the complete affected matrix
is rerun.

This document defines M0-016 intake and freshness evidence. M7-015 owns the
release-response SLA, notification and downstream publication runbook.
