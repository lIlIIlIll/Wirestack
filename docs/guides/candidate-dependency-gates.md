# Run installed candidate dependency gates

Use `tools/m12_004_candidate_gates.py` to exercise the AWS-LC upgrade archive without rebuilding the default 5.5.0 provider. The driver records development evidence. It does not authorize a release, change the production dependency pin, or sign an artifact.

## Prerequisites

- The qualified STS 1.1.3 SDK and `$HOME/.codex/scripts/codex_cangjie_env`.
- Linux x86_64 with glibc, Bubblewrap, OpenSSL, Python 3, and a disk-backed scratch directory with at least 2 GiB free.
- `docs/evidence/M12-004/upgrade/candidate.tar.gz` and its successful upgrade report.
- The retained pre-upgrade archive with artifact-byte SHA-256 `e430f08ff8596b1c43c1d1090b5c42d721abac3c03505656b2aea107ee7a079f`. Set `BASELINE_ARCHIVE` to that file. A regenerated or historical M8 rollback archive is not a replacement.

## Execute the candidate campaign

Allocate a new private child of disk-backed `$HOME/.cache/agent-tmp`. The driver refuses an existing work directory so that compiled test binaries cannot leak between runs.

```sh
WORK_ROOT="$HOME/.cache/agent-tmp/wirestack-candidate-gates-$(date +%s)"
$HOME/.codex/scripts/codex_cangjie_env \
  --sdk-root "$HOME/cangjie_sdk/sts1.1.3" -- \
  python3 tools/m12_004_candidate_gates.py \
  --sdk-root "$HOME/cangjie_sdk/sts1.1.3" \
  --baseline "$BASELINE_ARCHIVE" \
  --work-root "$WORK_ROOT" \
  --output docs/evidence/M12-004/candidate-gates/new-run
```

The report appears at `docs/evidence/M12-004/candidate-gates/new-run/report.json`. Each command retains normalized stdout and stderr. Private scratch keeps raw diagnostics and ephemeral test identities. Do not copy private keys into evidence or commit scratch.

An archive binding failure stops before execution. Resolve the selected artifact identity rather than changing the expected digest. A native or test failure remains a failure in the report; the driver does not substitute an easier target.

## What the driver exercises

The release archive reader verifies the complete package inventory before extraction. The driver compares the current production source files with that candidate and checks every extracted payload file before and after each gate. `build.cj` is forbidden. Bubblewrap hides the repository during CJPM builds; consumers depend on the extracted package.

TLS uses the existing M8-006 consumer, all 13 `RELEASE_MODES`, exact acceptance markers, and the existing external OpenSSL decrypt peer. It exercises TLS 1.2 and 1.3, signer success/error/cancellation/deadline, decryptor success/error/cancellation/deadline/short output, non-RSA rejection, and production keylog refusal.

Fuzzing copies six required current test sources and the ten existing manifest corpora into the isolated installation. Production sources and native archives remain unchanged. The M7-023 manifest loader, target executor, and classifier keep seed 7023, all ten targets, original iteration budgets, and original timeouts. Failure in one target does not remove later targets.

Performance builds both the exact previous archive and candidate with identical dependency manifests, STS, consumer flags, hardware, and M12-001 native workloads in one session. All 33 existing cases use one warmup and seven measured process rounds for each artifact. Artifact order alternates to avoid a fixed startup advantage. Existing workload validation, summary, frozen-noise thresholds, and baseline classification determine PASS, FAIL, NOISY, or INCONCLUSIVE. The TLS ratios also use the existing M7-024 threshold definitions and `DomainResult` checks.

The paired performance run does not replay historical M7-024 measurements as candidate results. The formal M7-024 stdx comparison, injected network profiles, and memory qualification remain `NOT_RUN` unless separately executed with candidate-bound inputs.

## Interpret qualification

`qualification` remains `NOT_QUALIFIED` even when every exercised development gate passes. The report names the actual Linux x86_64 glibc STS leg and records the unexecuted formal matrix separately.
The missing native qualification legs are the claimed Westmere minimum CPU, kernel 5.15, glibc 2.44 profile and independent namespace coexistence. AArch64 and musl are outside the accepted ADR scope; the driver does not invent additional supported platforms.

Required remaining evidence includes formal source freeze, approved independent source-bound security review, an authorized 86400-second formal soak, the full supported qualification matrix, and release/signing authorization. No short preflight is a substitute for the formal soak. This driver records the soak as `NOT_RUN` and does not create an assistant-authored security waiver.

Run the Python rejection controls with:

```sh
python3 -m unittest tools.tests.test_m12_004_candidate_gates -v
```

## Recorded M12-004 result

The final source-bound run is [candidate-gates/final2/report.json](../evidence/M12-004/candidate-gates/final2/report.json). [summary.json](../evidence/M12-004/candidate-gates/summary.json) provides the compact result and identifies superseded attempts.

Archive `bb12abafb87ffe60b3e3adbdf4c1ac6ea7f8da47a7a5ad8a2df58b9e8981556d` passed all 13 TLS modes and all ten fuzz targets. Both artifacts completed all 528 native performance samples with zero unexpected native failures. The performance gate failed its full-handshake P95 threshold: candidate/baseline ratio 1.2051572750772457 exceeded 1.20. Bulk throughput and full-handshake P50 thresholds passed. The existing baseline classifier reported 31 NOISY cases and two PASS cases, so the measurements do not establish a stable overall performance acceptance.

All 164 production sources, extracted payload files, native archives, selected archive bytes, qualified SDK files, and recorded gate inputs remained unchanged. The real CLI returned 1 for the performance failure. The original ten-test worker snapshot is preserved. The current six behavioral candidate controls pass within the 80-case combined integration invocation; copied constants/manifest values and CLI/mock forwarding checks were removed. The Python3.14 SyntaxWarning about the integrity-failure return in a finally block remains in the normalized log; it was not suppressed or counted as a gate pass.

Fresh [installed-source/CA](../evidence/M12-004/matrix/installed/index.json) and [Westmere native-floor](../evidence/M12-004/matrix/native-floor/index.json) captures now cover the separate selected-candidate legs; they do not modify this frozen report or qualify its failed performance comparison. Complete committed source freeze, approved security disposition, formal performance, 86400-second soak and release/signing authorization remain prerequisites. Do not rerun a failed threshold only to obtain a green report.
