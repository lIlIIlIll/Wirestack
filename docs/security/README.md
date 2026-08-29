# Security documentation

Start with the repository [security policy](../../SECURITY.md) for private
reporting and current support boundaries.

The [P0 threat model](threat-model.md) is the maintained human-readable security
baseline. Its machine-readable register is
[`threat-model.json`](threat-model.json). Together they cover supply chain,
trust and reference identity, key isolation, native callbacks, protocol parsers,
resource exhaustion, diagnostics, cancellation races and release evidence.

Security assurance is split across independent evidence:

- provider selection and build pin: ADR-0003;
- architecture/private-ABI audit: M7-020;
- ten-target release fuzz gate: M7-023;
- SBOM, provider manifest and fingerprint: M7-025;
- independent review and finding closure: M7-028/M7-029;
- artifact signing and update exercise: M7-030.

The first four have Linux evidence. The independent review and signing work are
not complete. The threat model does not replace native platform tests, fuzzing,
SBOM, signatures or the final release matrix.
