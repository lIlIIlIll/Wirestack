# M12-002 — Linux deployment matrix

## Workspace and scope

Only M12-002 / issue #183 was implemented. Two independent workers covered installed-source/SDK/CA behavior and binary/native/TLS coexistence; the main worker executed the minimum native CPU/kernel profile and integration.

[Workspace safety](workspace.json) records the GitButler workspace, logical `m12-002-deployment` branch, HEAD `7849ac46457b7b10d7d3a55f78616a4d2d722c3c`, main merge base `00d6864f8f5dee6a5c13a5a68144135e9e9601bc`, 242 preexisting dirty entries and actual toolchains. Unrelated changes, SDKs, sibling repositories and the existing unrelated VM were preserved. No commit, push, PR, issue mutation, signing or SDK build was requested or performed. [Dependencies](dependencies.json) records the completed M9-001 start dependency.

The selected development archive is `docs/evidence/M12-001/native-final/wirestack-baseline.tar.gz`, exact byte SHA-256 `e430f08ff8596b1c43c1d1090b5c42d721abac3c03505656b2aea107ee7a079f`. Its installed payload fingerprint is `6f7e9d20f021ffb84fa91a8cf28f7a17488b8e3fa17e607975ed2af6d568ac3e`. All 164 production inputs still match. Production code and the packaged README were intentionally unchanged.

This is working-tree task acceptance, **not formal release qualification**. No committed-source seal was requested.

## Acceptance criteria

| Criterion | Actual result and scope | Evidence |
|---|---|---|
| Native CPU/kernel/libc and toolchain floor | Stable SDK installed consumers and rebuild on KVM Westmere, no AVX/AVX2, kernel 5.15.0-198-generic, explicitly selected glibc 2.44; 47 unchanged-binary checks and 47 rebuilt checks pass | [Native report](platform/westmere-glibc244/report.json), [runtime provenance](platform/glibc244-runtime.json), [orchestration](platform/orchestration.json) |
| Separate source, binary ABI, semantics and recompilation | Stable 1.1.3 and selected candidate 1.3.0-alpha.06 source cells pass; exact coexist binaries execute under both selected runtimes; default consumer recompilation remains required after SDK changes | [Deployment cells](deployment-matrix.json), [source summary](source-sdk/summary.json), [binary acceptance](binary/verification.json) |
| Native and optional dependency closure | 333 ELF/archive scans, including shipped provider/resolver/filesystem archives, 266 SDK inputs, 30 compiled optional-module archives, ten installed consumers and two coexist executables; no absolute dynamic-loader path hazards or implicit system TLS dependency in produced consumers | [Binary report](binary/report.json), [external inputs](../../references/linux-deployment-inputs.json) |
| Installation, relocation and trust diagnostics | Both source profiles build with the checkout hidden, run after whole-tree relocation, execute operational CLI/raw/gzip/streams/service paths and six CA scenarios each, including missing and wrong explicit/system CA errors | [Stable](source-sdk/stable-native/report.json), [candidate](source-sdk/candidate-native/report.json), [source guide](../../guides/linux-source-sdk-compatibility.md) |
| Other dependency and independent TLS coexistence | Independent Cangjie/native arithmetic, verified Wirestack TLS, verified independent TLS, cleanup followed by fresh Wirestack TLS and same-process identity pass in all four exact SDK/runtime combinations | [Capture](binary/report.json), [main direct smoke](integration/coexist-smoke.json), [safe boundary and failed namespace](binary/unsafe-namespace.json) |
| Drift invalidates old qualification | Current verification binds SDK compiler/CJPM/runtime/library bytes, production sources, native tools/archives, scanned binaries, fixture sources and diagnostics; real replaced-runtime and recompressed-archive probes are rejected | [Input rejection](binary/input-rejection.json), [source-bound verification](verification.json), `tools/m12_002_deployment.py` |
| Documentation and excluded targets | API index links the deployment contract; source and binary guides state exact tested scope; aarch64 prerequisites are recorded, musl remains deferred, Windows/macOS are excluded | [Deployment guide](../../guides/linux-deployment-matrix.md), [binary guide](../../guides/linux-binary-compatibility.md), [API index](../../api/README.md) |

## Executed verification

| Command / scenario | Result |
|---|---|
| `python3 tools/m12_002_source_sdk.py --sdk-root "$SDK_ROOT" --archive "$ARCHIVE" --verify "$SOURCE_REPORT"` for each exact selected SDK | Exit 0 each; `M12_002_SOURCE_SDK_VERIFY_PASS` |
| Stable and candidate installed consumers, checkout hidden and relocated | 47 native scenario checks per SDK plus six CA cases per SDK pass |
| Native VM `tools/m12_002_platform.py` through the controlled glibc namespace | Exit 0; `M12_002_NATIVE_PLATFORM_PASS same_binary=47 rebuilt=47` |
| `python3 tools/m12_002_platform.py --stable-report "$STABLE_REPORT" --verify "$NATIVE_REPORT"` | Exit 0; `M12_002_NATIVE_PLATFORM_EVIDENCE_PASS` |
| Binary capture attempt 9 and its `--verify` invocation | Exit 0; `M12_002_BINARY_BINDING_PASS`; four real native coexist executions |
| Main direct replay of all four captured coexist commands with checkout hidden | Exit 0; `M12_002_MAIN_COEXIST_SMOKE_PASS combinations=4 behavior_checks=20` |
| `python3 tools/m12_002_deployment.py contracts` with selected SDK environment and disk-backed temporary directory | Exit 0; 17 behavioral tests, no skips |
| `python3 tools/architecture_guard.py --root . --format text` after fixture and typed-digest corrections | Exit 0; `architecture guard: PASS` |
| `scripts/check-m7-032-public-api --json` | Exit 0; acceptance PASS, 363 declarations |

Canonical final integration [task gate](task-gate.json) passed both commands with exit 0: seventeen behavioral contracts without skips and current source/binary/native evidence verification. The scoped `git privacy-check --message` scan also exited 0. Set `WIRESTACK_STABLE_SDK_ROOT`, `WIRESTACK_CANDIDATE_SDK_ROOT` and `WIRESTACK_BINARY_CAPTURE_ROOT` to the exact retained qualified installations/capture before running:

```bash
python3 tools/m12_002_deployment.py collect \
  --binary-report docs/evidence/M12-002/binary/report.json
scripts/check-task M12-002 --json \
  --output docs/evidence/M12-002/task-gate.json
python3 tools/m12_002_deployment.py verify
```

A JSON report alone cannot reverify removed scanned binaries. The capture directory and selected native tools/library bytes must remain available or the affected profiles must be recaptured. Temporary data uses disk-backed per-task storage, not tmpfs `/tmp`.

## Retained failures and limits

- Stock guest glibc 2.35 rejected the unchanged stable CLI before program execution because its closure imports GLIBC_2.38, GLIBC_2.43 and GLIBC_2.44. The other three consumers and source rebuild were not attempted under 2.35. [Failure](platform/westmere/report.json) is not a passing support cell.
- The passing VM profile installs selected glibc 2.44 in a private read-only mount namespace; it is not stock Ubuntu 22.04 support. Outside the namespace, guest glibc remained 2.35. Host and guest root filesystem glibc files were not overwritten.
- The earlier `dlmopen` candidate/candidate execution exited 139 after independent TLS cleanup. The retained core diagnosis shows AWS-LC thread-local access receiving `-1`. Duplicate libc/pthread key-allocation-domain corruption is an inference, not a proven SDK ABI incompatibility. Earlier occasional namespace passes do not qualify that unsafe profile.
- Supported coexistence uses a **test-only**, explicitly selected `dlopen` deep-binding boundary with distinct SSL/crypto owners and shared base libc/pthread ownership. Ordinary unisolated global OpenSSL coexistence is UNSUPPORTED. Production provider loading and fallback behavior were not changed.
- Official VM image bytes match the official HTTPS checksum. Its detached signature was not verified. Historical shipped native compiler executable digests and SDK upstream build flags remain UNKNOWN; current fingerprints do not retrospectively qualify historical builds.
- Candidate SDK on the minimum VM, older kernel/libc/CPU combinations, aarch64, musl, Windows and macOS are unverified or excluded. Raw ISA presence does not establish a minimum CPU.
- The unchanged full/fast repository documentation gate has a known dependency `cjdoc` heap OOM at 256 MiB. It was not rerun or reported as passing.
- [Retention](retention.json) confirms the owned VM supervisor exited 0 and its process is absent; the unrelated VM was untouched. Removed 4,305,130,633 bytes of recoverable images, transfer archives and agent scaffolds. Retained logical bytes: binary 16,269,460,915, source SDK captures 397,280,111 and platform failures/provenance 5,570,603, under `$HOME/.cache/agent-tmp/wirestack-m12-002.XCXlIZ/{binary,source-sdk,platform}`. The binary evidence includes the 614,850,560-byte diagnosed core and the exact binaries required by the verifier.

M12-003 and M12-004 remain READY. Neither was started.
