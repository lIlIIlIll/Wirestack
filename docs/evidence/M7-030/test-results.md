# M7-030 test results

Date: 2026-08-30

Platform: Linux x86_64 glibc 2.44

Local validation toolchain: Cangjie `1.1.0-alpha.20260817040003`, CJPM `1.1.3`

Hosted signing mode: frozen artifact; no compiler or artifact rebuild

## Local results

| Command | Result |
|---|---|
| `python3 tools/repository/repository_tooling.py --root . validate-tasks --json` | PASS; M7-030 task contract accepted. |
| `python3 tools/repository/repository_tooling.py --root . validate-plan docs/evidence/M7-030/test-plan.md --json` | PASS; 26 paths, 23 scenarios and 19 planned tests. |
| `python3 -m unittest tools.tests.test_m7_030_linux_release -v` | PASS; 12/12 tests. |
| `scripts/generate-m7-025-linux-supply-chain --validate-only` | PASS; artifact `c0988f62eb657c465a928825573e41e2eb2675241240312bc2228482cbafc9ee`, build fingerprint `67dcd09f0ab99a33cfb204fb5f2a133a911f8f706ccf85a7a3312b980ddac9d9`. |
| `scripts/release-m7-030-linux validate-workflow --output docs/evidence/M7-030/workflow-contract.json` | PASS; exact frozen tag and SHA-256, isolated staging and attestation permissions, three attestation subjects and seven immutable action references. |
| `scripts/check-m7-030-release` | PASS as `REHEARSAL`; three detached signatures, clean consumer, update, advisory and authorized rollback passed. The separately validated production attestation is PASS. |
| `scripts/check-fast --json --output build/m7-030/check-fast.json` | PASS; task-contract fast gate. |
| fixed-SDK `scripts/check` outside the restricted socket sandbox | PASS; Python tool tests, gate tests and benchmark tests passed; `cjpm check`, `cjpm build` and `cjpm test` passed. Cangjie summary: 592 total, 569 passed, 23 skipped by the repository's non-Performance selection, 0 error, 0 failed. The skipped cases are not reported as PASS. |

The first `scripts/check` attempt inside the restricted sandbox failed before
test execution because `std.unittest` could not create its local socket and
returned `SocketException: Operation not permitted`. The same command then ran
outside that socket restriction and passed. This was an environment failure,
not a source or assertion failure.

## Hosted failure injection

GitHub-hosted run `33315568568` on merge commit
`f9753199daf1d6869e46971785eb8d80d1fbad3d` failed in the toolchain install
step with `Nightly version not available: 1.1.0-alpha.20260817040003`. Every
build, signing, verification, report and upload step was skipped, so the run is
recorded as FAIL and supplied no production evidence.

Run `33316074236` on merge commit
`4bd302dd50e310474c66bf3d412f47044e6fd5c5` installed Cangjie
`1.3.0-alpha.20260830010011` and passed release qualification, then failed
M7-025 validation because the hosted rebuild overwrote the frozen artifact with
different bytes. Every attestation, verification, report and upload step was
again skipped. The final workflow removes compiler installation and artifact
rebuilding; it validates and attests the exact M7-021/M7-025 bytes instead.

Run `33316521268` on merge commit
`6d14c5ae3f05a63ae93f026c9a2862854434a3b7` failed before supply-chain
validation because the clean checkout did not contain the Git-ignored frozen
artifact. Every attestation, verification, report and upload step was skipped.
The approved repair stores the exact bytes in an unpublished draft Release and
requires a fixed tag, asset name and SHA-256 before validation or signing.

The draft Release upload and an independent download both reported 2,499,451
bytes and SHA-256
`c0988f62eb657c465a928825573e41e2eb2675241240312bc2228482cbafc9ee`.

Run `33317478966` on merge commit
`fcb50e00286cbff50711f871e2818901163134ea` failed in the exact asset download
step with `release not found`. The job used `contents: read`; every signing,
verification, report and upload step was skipped. The next workflow revision
isolates draft access in a `contents: write` staging job with no OIDC, then
reverifies the transferred bytes in the read-only attestation job.

Run `33317831996` on merge commit
`decedefa5e9638032838ca414e47f85e3cb3bc84` passed draft download, both
SHA-256 checks, M7-025 validation, manifest generation and all three
attestation steps. The first `gh attestation verify` failed because the signer
workflow was supplied as a relative path. Downloading the published artifact
bundle and verifying it offline with the repository-qualified identity returned
one verified attestation. No bounded hosted report was produced by this failed
run.

## Hosted success

Run `33318194490` on merge commit
`8367a4eae8c4d46600dc1d20e571e9a3ddf5a493` completed both jobs. It
downloaded the exact draft asset, verified its SHA-256 before and after job
transfer, validated M7-025, created and verified the artifact, SBOM and release
manifest attestations, produced the bounded report and uploaded all evidence.
The downloaded artifact digest is
`c0988f62eb657c465a928825573e41e2eb2675241240312bc2228482cbafc9ee`.
The byte-identical downloaded `github-attestation.json` has SHA-256
`d3f553ca325c5ee7ed90039c6673172be886cbb64680ff9763eac9a66e3f9e35`
and passes `scripts/release-m7-030-linux validate-hosted`.

## Task-level result

`scripts/check-task M7-030 --json --output
docs/evidence/M7-030/task-check.json` ran all six commands. All six passed,
including `github-hosted-attestations`; the overall task result is PASS.

`hosted-validation.json` binds the hosted report SHA-256, commit and all three
verified subjects. `task-check.json` binds the six acceptance commands.
`scripts/verify-evidence M7-030 --json` returns PASS with two indexed reports,
23 source digests and no stale path.

## Current acceptance state (2026-10-22)

The results above are the 2026-08-30 record and are unchanged history. On the
current tree the frozen-artifact prerequisite now runs before any manifest,
signing or update work: `scripts/check-m7-030-release` first stages
`frozen-artifact.json` and the rehearsal refuses the run when the asset name,
2,499,451-byte length or `c0988f62…` SHA-256 differs, or when the pinned draft
Release cannot supply it.

The task check runs all six acceptance commands and returns FAIL. Two are red
and four pass:

| Command | Current result |
|---|---|
| `test-plan-matrix` | PASS; 27 paths, 24 scenarios and 20 planned tests. |
| `signing-update-fault-injection` | PASS; `python3 -m unittest tools.tests.test_m7_030_linux_release` in the worktree and in a clean `git archive` export that has no `dist/` directory. The suite now also covers receipt preservation for download failure, size mismatch and digest mismatch. |
| `supply-chain-inputs` | FAIL exit 1, `generator fingerprint is stale`: recorded `42e064cf…` versus current `b7a15290…`. M11-002 (`0a3161e5`) changed `tools/m7_025_linux_supply_chain.py` after the M7-025 evidence was frozen; regenerating that bundle is M7-025 work. |
| `hosted-workflow-contract` | PASS; frozen mode, isolated staging and attestation permissions, three subjects. |
| `local-signing-update-rehearsal` | PASS as `REHEARSAL`, but `productionAttestation` now records `{"decision": "FAIL", "detail": "HOSTED_REPORT_SUBJECT"}` instead of the inherited historical PASS. The command itself does not record which staging mode it used; the committed receipt's mode is stated separately below. |
| `github-hosted-attestations` | FAIL exit 1, `HOSTED_REPORT_SUBJECT`: the committed report predates the required `signedPayloadSha256` subject field, and the workflow is retired with M8-007 as the active signer. |

On this stacked branch, where P1-012 scopes dependency validation to the
requested task closure, `scripts/check-task M7-030 --json` runs all six commands
and reports `status: FAIL` with exactly the two failing commands above and
`issues: []`. The unscoped repository-wide readiness check still reports
`DEPENDENCY_INCOMPLETE` on the unrelated `M10-004 → M10-003` edge. M7-030's own
dependencies M7-022, M7-025 and M7-029 are COMPLETE. In a fresh clean checkout
with no `dist/` directory, `supply-chain-inputs` fails earlier with
`release artifact is absent`, before any fingerprint comparison: the
`--validate-only` mode has no artifact to inspect. The stale-generator
diagnosis above applies only once a staged artifact is present.

Marking this task BLOCKED also propagates to M7-031, which lists M7-030 as a
dependency and whose `validate_dependency_status` requires
`| M7-030 | COMPLETE |` in `docs/planning/status.md`. The
`scripts/check-m7-031-release` gate therefore reports
`DEPENDENCY_INCOMPLETE: M7-030`. The unittest discovery failure was fixed
separately in draft PR #239: `python3 -m unittest
tools.tests.test_m7_031_linux_candidate -v` passes four dependency-readiness
tests and skips `M7031LinuxCandidateTests` with
`M7-031 prerequisites are not COMPLETE: M7-030`; its fifteen candidate
methods do not run. The underlying gate already failed on the base commit
with `DIGEST_INVALID: M7-030 artifact signed payload`, so M7-031's COMPLETE
record was not supported by its own gate before this change. M7-031's row,
tooling and evidence stay untouched here because they are outside this task's
`allowed_paths`.

Running the gate has three evidence-report side effects, not two. Before this
change it regenerated `frozen-artifact.json`, `local-rehearsal.json` and
`hosted-validation.json` in place, so after a run the working tree showed all
three files modified even though the rehearsal and hosted verdicts were
unchanged in kind. None of the three is rewritten here. `local-rehearsal.json` and
`hosted-validation.json` keep their 2026-08-30 bytes, and
`frozen-artifact.json` keeps the receipt first committed on 2026-10-22, which is
what the historical record documents. The gate
script now stages its receipt under the Git-ignored `build/m7-030/` directory
instead of `docs/evidence/M7-030/frozen-artifact.json`, and the tool refuses to
write a failure payload to that receipt at all, so a failed staging or digest
check can no longer replace the committed PASS receipt; the two remaining
in-place evidence rewrites are `local-rehearsal.json` and
`hosted-validation.json`. The receipt is also listed in the task manifest's
`source_paths` and `required_evidence`, so its deletion or tampering is detected
rather than silently accepted.

## Unit-test isolation (2026-10-22)

The fault-injection suite originally read the ignored `dist/m7-021` staging
archive, so its verdict depended on an ambient build product: on a clean
checkout of the branch head 10 of 19 tests failed with `FROZEN_ASSET_MISSING`
or `ARTIFACT_STALE`. The suite is now hermetic. A `frozen_fixture` context
manager materialises a tiny deterministic `wirestack-0.1.0` archive in a
temporary directory, copies the committed M7-025 documents beside it, rewrites
the copied `bundle.json` so its artifact entry names that payload, and pins
`ARTIFACT`, `SUPPLY_CHAIN`, `SBOM`, `FROZEN_ARTIFACT_BYTES`,
`FROZEN_ARTIFACT_SHA256` and the workflow text for the duration of the block
with `unittest.mock.patch.object`. Production constants are never rewritten:
the committed `FROZEN_ARTIFACT_NAME`, tag, 2,499,451 bytes and `c0988f62…`
digest keep their real values, and the unpatched suite cross-checks them
against both the committed M7-025 bundle and the committed
`frozen-artifact.json` retrieval receipt.

The negative tests keep their teeth independently of the fixture: a renamed
copy still trips `FROZEN_ASSET_NAME`, a one-byte-short copy trips
`FROZEN_ASSET_SIZE`, a same-length single-bit flip trips `FROZEN_ASSET_DIGEST`,
an absent staging path trips `FROZEN_ASSET_MISSING` for both
`build_release_manifest` and `fetch_frozen_artifact`, and a failed `gh release
download` trips `FROZEN_ASSET_DOWNLOAD` without leaving the asset behind.
Replacing `verify_frozen_artifact` with a permissive stub fails those tests, so
they observe the check rather than the fixture.

Supporting the injection required resolving path defaults at call time in
`tools/m7_030_linux_release.py`: `build_release_manifest`,
`verify_frozen_artifact`, `fetch_frozen_artifact`, `create_offline_bundle`,
`verify_offline_bundle` and `inspect_workflow` now take `None` and fall back to
the module attribute, and a new `workflow_text()` seam supplies the default
workflow source. Behaviour with no arguments is unchanged, and
`scripts/check-m7-030-release` still fetches and verifies the exact pinned draft
asset, so the local release contract remains as strict as before.

### Clean-checkout acceptance

Running the canonical gate in a `git archive` export of `9ddc2c2a`, which has no
`dist/` directory, exercises the retrieval path rather than reusing a staged
copy:

```
$ scripts/check-task M7-030 --json
test-plan-matrix                  PASS
signing-update-fault-injection    PASS
supply-chain-inputs               FAIL
hosted-workflow-contract          PASS
local-signing-update-rehearsal    PASS
github-hosted-attestations        FAIL
status FAIL, issues []
```

That export has no `dist/` directory, so the supply-chain command in it fails
before any fingerprint or digest comparison: `scripts/generate-m7-025-linux-
supply-chain --validate-only` reports `release artifact is absent`. The
stale-generator-fingerprint FAIL described above is what a tree with a staged
artifact reports instead; the two are different failure points and are not
interchangeable.

The receipt committed in this branch records
`"mode": "verified-existing-artifact"`, not a download. No current captured
receipt shows `downloaded-and-verified-frozen-artifact`, so that mode is not
claimed here: the committed receipt documents verification of an already present
artifact, and any future download-mode capture must be committed as its own
report rather than inferred from this one. The fail-closed staging logic itself
is exercised only by the injected-runner unit tests, which assert that a failed
download, a wrong-size payload and a digest mismatch each publish nothing.

## Gates not run

- The one-hour SSE profile was not run.
- A second 86,400-second soak was not run; M7-022 already owns and completed the
  final artifact soak.
- No SDK, runtime, std, stdx, non-Linux or self-hosted-runner gate was run.
