# P1-014 evidence digest boundary

## Status

The development task is **COMPLETE**. After all shared completion metadata
froze, the real Linux/Windows pair executed at
`756162212073523a61cb6e23330eb07ceef0685d`; Windows run `41841419255`
checked actual CRLF bytes, and the independent Linux receipt has the same
normalized digest. Strict verification passed for all six reports and 84
source paths at that exact source. The source is public.

GitHub incident `smtdswd1h2w4` is no longer a publication blocker. The original
stale verification, server failures and intermediate recovered pair remain in
`maintenance/recovered-metadata/`. See
[final metadata qualification](current-metadata-status.json). Native execution
revisions, source inventories, timeouts and thresholds were not edited to
bypass the final-source rerun.

The post-integration selected task passed all five commands at code source
`1631837216989f7eac6986b24b0b9a2c61d0bd20` on qualified official STS 1.1.3.
All 150 focused regressions passed. The unchanged 1,800-second canonical
command completed in 685.409 seconds, with 1,090 native passes, 28 explicit
skips, and no failures or errors. Complete command projections and their
original-byte and public-text digests are retained in
[current-source qualification](maintenance/current-source-v5/qualification.json).

The initial post-integration Linux/Windows pair both passed at exact metadata
source `b78d8d278214bd981572ac82581b185489bab40c`; Windows workflow
`41808713685` produced actual CRLF bytes, while the independent Linux checkout
produced LF bytes with the same normalized digest. That pair is retained
separately under `maintenance/current-source-v5/`. The latest canonical
receipts and evidence seal must identify the same frozen metadata revision;
later status changes require another native pair and seal, not revision edits
to older receipts.

The table below remains historical. Its PR #151 reports do not qualify current
source, and no release qualification is claimed here.

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
  launches, `openssl dgst`, GNU `cksum` SHA-256, embedded Python SHA-256 and unmarked shell/workflow
  hash commands fail the guard. Python files under `tools/`, `scripts/` and
  `.github/actions/`, non-Python files under `tools/`, and every composite
  action/helper under `.github/actions/` are scanned. Folded YAML commands are
  reconstructed before operand classification even when their domain comes
  from the command manifest; literal shell blocks retain per-command operands.
  PowerShell/.NET SHA-256 APIs and unreadable UTF-8 helpers fail closed. Pure local wrappers propagate
  their digest domain and forwarded argument through arbitrary wrapper depth;
  assigned callable aliases are resolved to the same typed operation.
  Typed equality helpers parse both serialized domains and reject bare strings;
  fixed string and digest-map fields owned by pre-existing task or protocol
  schemas use separately named schema-domain comparators. Direct equality on
  every digest-bearing field name is rejected, including fields assigned to a
  local variable before equality or `hmac.compare_digest`. Literal `.log` and all declared text
  suffixes cannot enter the artifact-byte domain. The inventory is required to
  contain no legacy entry.
- The architecture guard rejects raw SHA-256 outside the typed implementation,
  ambiguous digest helpers, positional, keyword and assigned text paths entering
  the byte domain, untyped repository-evidence comparisons and UTF-8-to-byte
  fallback. Text inventories reject NUL bytes to keep multi-file framing
  unambiguous, and artifact-domain markers cannot approve obvious text operands.
- Native CRLF probes read a tracked checkout fixture, reject matching `-text`
  and `eol=lf` attributes, require actual CRLF bytes on Windows, and compare the
  complete OS, architecture and libc identity. `.gitattributes` changes trigger
  the hosted Windows probe. Both retained platform reports must match the exact
  candidate revision; resealing an older report fails with `REPORT_REVISION`.
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

## Retained historical local evidence

| Evidence | Result |
|---|---|
| Test-plan validator | PASS, 13 paths, 7 scenarios, 11 tests |
| P1 task-contract unit and fault-injection tests | PASS, 120 tests |
| Repository-tool Python regressions | PASS, 407 tests |
| Architecture guard | PASS, 0 violations |
| Linux CRLF probe | PASS |
| Digest callsite inventory | PASS, 398 explicitly classified calls, 0 issues |
| GitHub Windows CRLF probe | PASS, run `33536032265`, source head `fc4b54a7`, merge `1f1d7be5`; effective `text` and `eol` attributes are `unspecified`, tracked fixture checked out as CRLF |
| Hosted exact-SHA CI | PASS, 25/25 checks at source head `fc4b54a7`, including architecture, clean Cangjie build, harness, Linux/macOS/Windows provider matrices, and Windows CRLF |
| `scripts/check-fast --json` | PASS |
| `scripts/check` | PASS, including 178 gate Python tests, 24 benchmark Python tests, and 588 passed/23 skipped Cangjie tests |
| `scripts/check-task P1-014` | PASS, all four commands passed |

## Commands

```text
python3 tools/repository/repository_tooling.py --root . validate-plan docs/evidence/P1-014/test-plan.md --json
python3 -m unittest tools.repository.tests.test_repository_tooling tools.tests.test_architecture_guard tools.tests.test_p1_014_evidence_digest_types -v
python3 tools/architecture_guard.py --root . --format json
python3 tools/evidence_digest.py --root . inventory --output docs/evidence/P1-014/digest-inventory.json
python3 tools/evidence_digest.py --root . crlf-report --expected-platform linux-x86_64-glibc --expected-revision <frozen-metadata-sha> --output docs/evidence/P1-014/linux-crlf.json
```

The current task manifest runs the architecture guard and digest-callsite
inventory directly. It retains plan validation, digest-boundary regressions
and the canonical `scripts/check`. It does not invoke the repository-wide
`scripts/check-fast`; that command evaluates unrelated task manifests and
remains a separate strict global-readiness diagnostic.

## Unrun gates

The one-hour SSE profile, 86,400-second soak, release rebuild, performance,
fuzz, security-review and signing gates were not run. None is part of the
non-long-running P1-014 task contract.

Retained pre-migration root evidence is still rejected rather than silently
promoted to schema v2. This does not describe the separately refreshed
`current-desktop` native resolver reports or current M3-031 provider reports.
The regression suite preserves fail-closed rejection of old schema and
pre-migration license-file digests.
