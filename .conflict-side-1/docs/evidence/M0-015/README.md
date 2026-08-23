# M0-015 evidence: TLS provider candidate matrix

## Status

- Task: **COMPLETE**
- Final provider selection: **NOT MADE**
- M0-016 six-platform PoC: **READY after merge**
- M0-020 provider ADR: **BLOCKED** by M0-016 and M0-018

## Output

- [`../../architecture/tls-provider-candidates.json`](../../architecture/tls-provider-candidates.json)
  is the canonical machine-readable candidate matrix.
- [`../../architecture/tls-provider-candidate-matrix.md`](../../architecture/tls-provider-candidate-matrix.md)
  explains the shortlist and freezes the M0-016 proof obligations.
- `tools/validate_tls_provider_matrix.py` fails closed when criteria, platform
  cells, evidence links, licensing disposition or shortlist invariants drift.

## Shortlist

```text
Primary PoC     AWS-LC
Secondary PoC   Mbed TLS
Control PoC     vendored OpenSSL 3.x
Reference only  BoringSSL
Conditional     rustls-ffi
```

Excluded from the default path:

```text
wolfSSL          incompatible default GPL/commercial licensing model
s2n-tls          upstream platform scope does not cover Wirestack P0
platform-native  no single six-platform engine or Linux default
BearSSL          no TLS 1.3
```

## Important non-claims

- The matrix does not prove that any external provider runs on HarmonyOS.
- Portable C/Rust and cross-compilation are not native platform evidence.
- Feature documentation is not evidence of cancellation, Deadline, truncation
  or partial-I/O behavior through the Wirestack Transport SPI.
- No provider is selected until M0-016 runtime evidence and M0-018 threat-model
  results are reviewed in M0-020.

## Source policy

Only upstream project or platform-owner sources are used as decision evidence.
The matrix records moving upstream links at the family-screening stage; M0-016
must pin exact commits, recursive dependency digests, license notices and patch
sets before building a candidate.

## Verification

```bash
python3 tools/validate_tls_provider_matrix.py
python3 -m unittest discover -s tools/tests \
  -p 'test_validate_tls_provider_matrix.py' -v
```
