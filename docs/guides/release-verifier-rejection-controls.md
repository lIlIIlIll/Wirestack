# Exercise release verifier rejection controls

Use `tools/m12_004_verifier_controls.py` to test the existing release verifiers without production signing. The driver copies inputs into an isolated directory, creates disposable `TEST_ONLY` Ed25519 keys, applies one mutation at a time, and requires the expected rejection code.

This is a non-production rehearsal. A `PASS` result remains `NOT_QUALIFIED` and does not authorize an upgrade, rollback, production signature, or release.

## Prerequisites

- Linux with Python 3, OpenSSH `ssh-keygen`, and a C compiler named `cc`.
- The existing `dist/m7-021/wirestack-0.1.0-linux-x86_64-glibc.tar.gz` and its M7-025 supply-chain documents.
- `docs/evidence/M12-001/native-final/wirestack-baseline.tar.gz` and the historical M8-007 fuzz report.
- A disk-backed scratch directory outside the repository. The driver does not execute a Cangjie SDK. Its report retains the `STS_ONLY` SDK policy.

Do not substitute candidate evidence for historical evidence, edit the legacy documents, or change trusted production signer keys to make this rehearsal pass.

## Run the controls

Check the scratch filesystem and available space before creating a private task directory.

```sh
stat -f -c %T "$HOME/.cache/agent-tmp"
df -B1 "$HOME/.cache/agent-tmp"
scratch=$(mktemp -d "$HOME/.cache/agent-tmp/m12-004-verifiers.XXXXXX")
chmod 700 "$scratch"
TMPDIR="$scratch" TMP="$scratch" TEMP="$scratch" \
  python3 tools/m12_004_verifier_controls.py \
  --scratch-parent "$scratch" \
  --output docs/evidence/M12-004/verifier-controls/verification.json
rmdir "$scratch"
```

If the filesystem is `tmpfs`, select a disk-backed parent instead. Run the commands from the repository root. The CLI has a 180-second lifetime limit, and its external commands have individual timeouts. It removes its temporary child directory on normal completion or a handled failure. A forced process kill cannot guarantee cleanup. Remove only that invocation's private scratch directory after confirming no process still uses it.


Select a different installed native archive with `--native-artifact PATH`. The default remains the frozen M12-001 baseline. This option changes the archive used for payload collection, keylog rejection, static archive replacement, and the compiled ABI probe; it does not replace the historical offline signing fixture. The report binds the selected archive with an `artifact-bytes-v1` digest and verifies its original bytes remain untouched. Repository paths are relative; paths outside the repository are recorded as `<external-native-artifact>` without exposing filenames or local directories.

For an available upgraded candidate, add `--native-artifact docs/evidence/M12-004/upgrade/candidate.tar.gz` and select a separate output such as `docs/evidence/M12-004/verifier-controls/candidate-verification.json`. A candidate rejection-control PASS is still `NOT_QUALIFIED`.
The command exits zero only when every control rejects for the expected reason, the positive fixtures and native ABI smoke pass, the original input digests remain unchanged, and temporary signing material has been removed. It prints the structured report and writes it atomically. `FAIL` means a control accepted a mutation or returned the wrong rejection. `BLOCKED` means a required fixture or executable could not be used. Do not treat either as success.

## Rejection coverage

| Mutation | Existing verifier | Expected error |
| --- | --- | --- |
| Replace the release archive without changing its signed digest | `m7_030.verify_offline_bundle` | `SUBJECT_DIGEST` |
| Change an SBOM package version | `m7_030.verify_offline_bundle` | `SUBJECT_DIGEST` |
| Remove each artifact, SBOM, or manifest signature | `m7_030.verify_offline_bundle` | `SIGNATURE_MISSING` |
| Change provider source binding under the original signature | `m7_030.verify_offline_bundle` | `SIGNATURE_INVALID` |
| Sign a manifest for a different repository with the correct disposable key | `m7_030.verify_offline_bundle` | `MANIFEST_POLICY` |
| Sign the manifest with a different disposable key | `m7_030.verify_offline_bundle` | `SIGNATURE_INVALID` |
| Change the build fingerprint report while keeping the supply-chain bundle | `m7_030.build_release_manifest` | `SUPPLY_CHAIN_STALE` |
| Replace candidate input references in the copied fuzz report | `m8_007.verify_fuzz` | `STALE_FUZZ_INPUTS` |
| Add `key-log` capability or set `test_only_key_log` | `m7_021.collect_payload` | `KEYLOG_CAPABILITY_FORBIDDEN` |
| Replace the installed TLS static archive with same-size different bytes | `m7_021.collect_payload` | `NATIVE_ARCHIVE_PROVENANCE` |

The driver checks the valid signature on the wrong-repository manifest before testing the policy rejection. This avoids mistaking a broken signature for enforcement of source policy. The keylog and static archive controls use the existing production payload collector, not a separate capability validator.

All expected errors come directly from verifier-owned `.code` fields. The driver does not inspect exception messages to choose outcomes. An unrelated structured code cannot pass a control even if its detail text matches a historical keylog error.

## Evidence and limits

The observed M12-004 report records 13 passing controls, unchanged original input byte digests, restored offline signatures, and removal of temporary material. It binds the driver and existing verifier source through typed text digests, and mutation bytes through typed artifact digests. Command records contain normalized arguments, exit codes, and output digests. Private keys and raw signing output never enter the repository or report.

The historical fuzz baseline is explicitly `BLOCKED` with `STALE_FUZZ_INPUTS` in this checkout. The copied-report case proves rejection by that existing gate; it is not a fresh candidate fuzz campaign. The M7 offline signature fixture is not the current upgrade candidate. Both the initial M12-001 archive run and the final 5.11.0 run passed a compiled, linked and executed native ABI probe. `candidate-verification.json` binds the final archive and records all 13 rejection controls. These probes do not qualify either archive or replace the candidate's installed consumer, performance, matrix, security, independent approval, fuzz or 86400-second soak gates.

Wrong-source coverage here checks signed manifest bytes and repository policy. It does not emulate a GitHub OIDC identity or claim that hosted Sigstore source-digest validation ran. Production attestation remains in `m8_007.verify_signatures`, with separate production signing authorization.

Run the regression tests separately when needed. They invoke the real CLI, verifiers, disposable signing commands, and native smoke rather than mocked release verdicts.

```sh
python3 -m unittest tools.tests.test_m12_004_verifier_controls -v
```

The regression suite includes the real CLI control run, a second run using an external archive copy, and unexpected-code rejection tests. Historical evidence, SDKs, and production signing policy are unchanged. Shared verifier changes for this task expose structured error codes; the control driver does not replace those verifiers.
