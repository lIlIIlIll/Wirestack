# Linux 1.0 independent security review package

This directory is the reviewer entry point for Wirestack's Linux x86_64 glibc
release profile. It packages evidence; it is not the independent review or a
release approval.

Read the material in this order:

1. [Architecture and trust boundaries](architecture.md)
2. [TLS provider and native boundary](provider-and-native-boundary.md)
3. [Parsers and resource limits](parsers-and-limits.md)
4. [Keys, trust, and sensitive data](keys-trust-and-data.md)
5. [Known limitations](known-limitations.md)
6. [Reproduction procedure](reproduce.md)
7. [`evidence-index.json`](evidence-index.json)

The baseline threat model is
[`docs/security/threat-model.md`](../../threat-model.md), with its machine-readable
companion [`threat-model.json`](../../threat-model.json). Findings and closure
belong to M7-029.

Wirestack is pre-1.0 and does not promise source, API, ABI, or semantic
compatibility with experimental declarations. The M7-026 baseline is retained
for history only and is not a release gate. Review the current M7-032 public API
inventory instead.

