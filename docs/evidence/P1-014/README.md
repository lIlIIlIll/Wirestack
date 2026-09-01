# P1-014 evidence digest boundary

## Status

P1-014 remains in progress while the final repository check and evidence index
are resealed. Linux and GitHub Windows fault injection pass. GitHub Actions run
`33481830845` tested PR #151 head
`4f6e9ca57a22e850fdf2f227e4e8e00ba9e3aaaa` through merge revision
`a0c598accca2d7536ac836916796fd57161a673a`; artifact `9790220952` contains the
checked-in `windows-crlf.json`.

## Implemented boundary

- `TextEvidenceDigest` hashes strict UTF-8 after CRLF and bare-CR normalization
  to LF. Invalid UTF-8 fails with `TEXT_UTF8`; there is no byte fallback.
- `ArtifactByteDigest` hashes exact bytes and has a different serialized domain.
- Evidence schema v2 stores `{domain, sha256}` objects for every report and
  source digest. Schema v1, bare strings, unknown domains and mixed domains are
  rejected.
- `tools/repository/repository_tooling.py` uses only the text-evidence domain for
  JSON reports and manifest source paths.
- All repository SHA-256 callsites use an explicit text-evidence or artifact-byte
  entry. The inventory contains 215 text calls, 63 byte calls and the three raw
  SHA-256 operations encapsulated by the typed implementation; no legacy
  task-local call remains.
- The architecture guard rejects raw SHA-256 outside the typed implementation,
  ambiguous digest helpers, obvious text paths entering the byte domain,
  untyped repository-evidence comparisons and UTF-8-to-byte fallback.
- Existing point-in-time release records are not rewritten. Validators now
  report the affected M7-025, M7-026 and M7-032 records as stale until their
  owning release tasks regenerate them.

The implementation does not depend on `.gitattributes -text`. Those existing
entries remain unchanged because they belong to other tasks.

## Local evidence

| Evidence | Result |
|---|---|
| Test-plan validator | PASS, 13 paths, 7 scenarios, 11 tests |
| Focused unit and fault-injection tests | PASS, 64 tests |
| Architecture guard | PASS, 0 violations |
| Linux CRLF probe | PASS |
| Digest callsite inventory | PASS, 281 calls: 215 text, 63 artifact, 3 typed implementation |
| GitHub Windows CRLF probe | PASS, run `33481830845`, head `4f6e9ca5`, merge `a0c598ac` |
| Hosted Gate Harness | PASS, run `33481830876`, head `4f6e9ca5` |
| `scripts/check-fast --json` | PASS |
| `scripts/check` | FAIL, 337 tests with 2 pre-existing M2-004 evidence errors |
| `scripts/check-task P1-014` | FAIL because its final `scripts/check` command failed; its first three commands passed |

## Commands

```text
python3 tools/repository/repository_tooling.py --root . validate-plan docs/evidence/P1-014/test-plan.md --json
python3 -m unittest tools.repository.tests.test_repository_tooling tools.tests.test_architecture_guard tools.tests.test_p1_014_evidence_digest_types -v
python3 tools/architecture_guard.py --root . --format json
python3 tools/evidence_digest.py --root . inventory --output docs/evidence/P1-014/digest-inventory.json
python3 tools/evidence_digest.py --root . crlf-report --expected-platform linux-x86_64-glibc --output docs/evidence/P1-014/linux-crlf.json
```

## Unrun gates

The one-hour SSE profile, 86,400-second soak, release rebuild, performance,
fuzz, security-review and signing gates were not run. None is part of the
non-long-running P1-014 task contract.

The canonical repository check currently fails only
`test_dependency_evidence_rejects_source_and_native_report_drift` and
`test_repository_core_and_task_graph_audit_passes`. Both failures arise because
the concurrently modified M2-004 evidence set does not match the M3-031
dependency bindings. P1-014 does not modify or absorb those unowned files.
