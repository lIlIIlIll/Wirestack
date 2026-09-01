# P1-014 evidence digest boundary

## Status

P1-014 is complete. Linux and GitHub Windows CRLF fault injection pass, every
digest callsite has an explicit domain, and the task-level and canonical
repository checks pass. GitHub Actions run `33526854717` produced the retained
Windows report for PR #151 source head `594d352a` (merge revision `a074c511`).

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
  entry. Python direct imports, assigned subprocess commands, `os.system`/`os.popen`
  launches, `openssl dgst`, embedded Python SHA-256 and unmarked shell/workflow
  hash commands fail the guard. Python files under `tools/`, `scripts/` and
  `.github/actions/`, non-Python files under `tools/`, and every composite
  action/helper under `.github/actions/` are scanned. Folded YAML commands are
  reconstructed before operand classification, and unreadable UTF-8 helpers
  fail closed. Pure local wrappers propagate
  their digest domain and forwarded argument through arbitrary wrapper depth;
  assigned callable aliases are resolved to the same typed operation.
  Typed equality helpers parse both serialized domains and reject bare strings;
  fixed string and digest-map fields owned by pre-existing task or protocol
  schemas use separately named schema-domain comparators. Direct equality on
  every digest-bearing field name is rejected. The inventory is required to
  contain no legacy entry.
- The architecture guard rejects raw SHA-256 outside the typed implementation,
  ambiguous digest helpers, positional, keyword and assigned text paths entering
  the byte domain, untyped repository-evidence comparisons and UTF-8-to-byte
  fallback. Text inventories reject NUL bytes to keep multi-file framing
  unambiguous, and artifact-domain markers cannot approve obvious text operands.
- Native CRLF probes read a tracked checkout fixture, reject matching `-text`
  and `eol=lf` attributes, require actual CRLF bytes on Windows, and compare the
  complete OS, architecture and libc identity. `.gitattributes` changes trigger
  the hosted Windows probe.
- M7-030 records canonical text and signed-payload byte digests separately for
  SBOM subjects. License bundle manifests and their UTF-8 text files use the
  text-evidence domain; invalid UTF-8 fails closed with a structured CLI report.
- Provider-matrix CI validates pins and matrix structure before producing fresh
  native results. Full retained-result validation remains explicit and rejects
  pre-migration license-file digests.
- Existing point-in-time release records are not rewritten. Validators now
  report the affected M7-025, M7-026 and M7-032 records as stale until their
  owning release tasks regenerate them.

The implementation does not depend on `.gitattributes -text`. Those existing
entries remain unchanged because they belong to other tasks.

## Local evidence

| Evidence | Result |
|---|---|
| Test-plan validator | PASS, 13 paths, 7 scenarios, 11 tests |
| P1 task-contract unit and fault-injection tests | PASS, 103 tests |
| Repository-tool Python regressions | PASS, 392 tests |
| Architecture guard | PASS, 0 violations |
| Linux CRLF probe | PASS |
| Digest callsite inventory | PASS, 389 explicitly classified calls, 0 issues |
| GitHub Windows CRLF probe | PASS, run `33526854717`, source head `594d352a`, merge `a074c511`; effective `text` and `eol` attributes are `unspecified`, tracked fixture checked out as CRLF |
| Hosted exact-SHA CI | PASS, 25/25 checks at source head `594d352a`, including architecture, clean Cangjie build, harness, Linux/macOS/Windows provider matrices, and Windows CRLF |
| `scripts/check-fast --json` | PASS |
| `scripts/check` | PASS, including 178 gate Python tests, 24 benchmark Python tests, and 588 passed/23 skipped Cangjie tests |
| `scripts/check-task P1-014` | PASS, all four commands passed |

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

M2-004 and other existing repository evidence remain schema v1 historical
evidence. Current freshness and dependency validators reject it rather than
silently promoting it to schema v2. The repository regression suite asserts
that rejection as the required fail-closed behavior. Pre-migration M0-016 and
M3-031 Windows license-file digests are likewise rejected rather than rewritten.
