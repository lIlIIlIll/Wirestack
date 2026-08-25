# M6-019 Linux acceptance evidence

Date: 2026-08-25

## Scope and environment

- Target: native Arch Linux x86_64, kernel `7.1.9-arch1-2`.
- Cangjie compiler: `1.1.0-alpha.20260817040003`.
- cjpm: `1.1.3`.
- Task: close the HTTP/2 conformance, race and bounded deterministic-fuzz
  requirements. Continuous fuzz infrastructure remains M7-006 scope.

## Acceptance decision

| Acceptance criterion | Result | Evidence |
| --- | --- | --- |
| HPACK RFC vectors and bounds | PASS | The full gate requires the RFC integer, Huffman and shared-dynamic-state cases; all 431 repository tests passed. |
| Flow control and configured limits | PASS | Existing connection/stream window, SETTINGS delta, overflow and cleanup cases passed; new limit mutations reject oversized frame, block, field, list and table inputs. |
| Invalid order and CONTINUATION | PASS | A unified matrix rejects non-SETTINGS first frames, interleaving during an open header block, wrong-stream CONTINUATION and CONTINUATION without HEADERS at connection scope; valid fragments complete only at END_HEADERS. |
| RST_STREAM and GOAWAY races | PASS | Existing independent races passed, and 100 combined RST_STREAM+GOAWAY races completed the owner exactly once and left stream, flow and both listener registries empty. |
| Frame parser and HPACK deterministic fuzz | PASS | More than 200 frame and 250 HPACK seed/mutation/truncation executions ran under explicit limits; expected protocol/HPACK rejection is accepted and any other exception fails the test. |

## Gate definition

- `tools/gates/http2_quality.py` runs bounded subprocesses, validates the final
  project summary and required named cases, records exact tool/platform data,
  and fingerprints every HTTP/2 source and test file.
- `tools/gates/manifests/http2-quality.manifest` defines independent Linux
  conformance and deterministic-fuzz scenarios with 600-second outer bounds.
- The accepted source fingerprint was
  `d538835f19aca7cdcd35c15a17934c52670daab164cea49ccac469182f2d8eac`.

## Commands and exact results

All Cangjie commands ran from the repository root through the configured
Cangjie environment.

1. `cjpm test --no-run`
   - Exit 0; test-profile compilation finished.
2. `cjpm test --no-progress --no-color --filter Http2ConformanceTest`
   - Exit 0; 3 passed, 428 skipped, 0 errors, 0 failed.
3. `cjpm test --no-progress --no-color --filter Http2DeterministicFuzzTest`
   - Exit 0; 3 passed, 428 skipped, 0 errors, 0 failed.
4. `python3 -m unittest tools.gates.tests.test_http2_quality`
   - Exit 0; 4 tests passed.
5. `python3 tools/gates/gate_runner.py --manifest tools/gates/manifests/http2-quality.manifest --repo-root . --artifact-dir /tmp/wirestack-m6-019-gate-artifacts --output /tmp/wirestack-m6-019-gate-report.json --print-json`
   - Exit 0; `GATE-HTTP2-QUALITY` PASS.
   - `linux-http2-conformance`: PASS in 31.984 s; 431 passed, 0 skipped,
     0 errors, 0 failed.
   - `linux-http2-fuzz`: PASS in 9.639 s; 3 passed, 428 skipped, 0 errors,
     0 failed.
6. `scripts/check`
   - Exit 0.
   - Python repository tests: 50 passed.
   - Python gate and gate-runner tests: 67 passed.
   - Python benchmark-tool tests: 4 passed.
   - Architecture guard: PASS.
   - `cjpm check`, `cjpm build`, and the complete 431-test suite succeeded;
     431 passed, 0 skipped, 0 errors, 0 failed.
   - The build retained one existing unused-function warning for
     `waitUntilWaiters` in the HTTP/1 connection pool; it is outside M6-019.

## Remaining scope

M6-019 is complete on Linux. The HTTP/2 1/10/100-stream performance baseline,
percentiles, connection-count reduction, RSS, queue and flow-stall evidence are
M6-020 and are not claimed here.
