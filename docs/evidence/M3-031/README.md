# M3-031 desktop TLS adoption evidence

## Qualification boundary

M3-031 maps the desktop-applicable portion of the provider-neutral TLS Core
contract and validates pinned AWS-LC 5.5.0 on native Windows x86_64 and macOS
arm64 runners at one exact repository revision. This projection does not
complete historical global M3 tasks, M3-001's six-platform target-build
condition, or any mobile condition. Those remain explicitly excluded.

The current desktop and Core receipts qualify the frozen integrated source
`1631837216989f7eac6986b24b0b9a2c61d0bd20`. The immutable source ref is
`evidence/M10-002/1631837216989f7eac6986b24b0b9a2c61d0bd20`; the actual
workflow dispatch branch was `fix/M10-002-resource-owner-backpressure`.
The tested integrated revision is not presented as the lower M3 owner PR head.

This task does not implement Windows system trust, macOS system trust, Windows
key handles, Apple Keychain/SecKey, or mobile device support.

## Current executed results

- [Hosted provider run 41797923287](https://github.com/lIlIIlIll/Wirestack/actions/runs/41797923287)
  passed on Windows x86_64 and macOS arm64. Both schema-v11 AWS-LC 5.5.0
  reports passed all 18 required capabilities and retained 11 license files.
- [Windows resolver run 41797937351](https://github.com/lIlIIlIll/Wirestack/actions/runs/41797937351)
  passed all six selected cases on STS 1.2.0. [macOS resolver run 41797950640](https://github.com/lIlIIlIll/Wirestack/actions/runs/41797950640)
  passed all eight selected cases on STS 1.2.0. The other 28 Windows and 26
  macOS filtered cases and Apple mobile targets are not qualified.
- [Current Core qualification](current-core/qualification.json) passed its
  four executed commands on the qualified Linux STS 1.1.3 SDK: provider build,
  architecture guard, provider substitution, and outside-checkout installed
  HTTPS consumer. Its nine logs retain typed text digests.
- The full `scripts/check-task M3-031` run passed all five commands. The
  [audit](core-prerequisite-audit.json) and
  [matrix](desktop-provider-matrix.json) are retained gate outputs, not
  hand-authored PASS records.
- The full historical M3-030 verifier returned `HISTORICAL`, integrity
  `STALE`, code `STALE_SOURCE`: its `task-check.json` report digest changed.
  This diagnostic does not promote M3-030 or qualify current Core.

The native provider ZIPs were checked byte-for-byte against every retained
platform payload. Their artifact-byte SHA-256 values are recorded in
`hosted-run.json`. The current Core release disposition remains
`NOT_QUALIFIED`; its raw archive is not a published release artifact.
The hosted provider workflow did not upload `build.log`, so those log bytes are
not claimed as verified. This does not replace or weaken the nine full
current-Core logs, which are retained separately.

The macOS resolver ZIP also contained inherited prior-source acquisition
commentary. Its bytes matched the frozen source, but it was excluded from
current native acceptance. The current parent acquisition receipt records that
exclusion; all seven authoritative native files remain unchanged.

## Task-graph boundary

The M3-031 task manifest has no recursive task dependencies. Its acceptance
directly validates the current-desktop report and validation pair for M2-004
(Windows x86_64) and M2-006 (macOS arm64), each bound to its pinned STS SDK,
current source inventory, executed native cases, and retained logs. The legacy
generic M2 evidence indexes, global M2 task statuses, and M2-006 iOS evidence
are not M3-031 inputs. This scoped projection does not rewrite or promote any
M2 status or evidence. M3-030 reports still receive the full historical
identity, inventory, digest and provenance check, but failures are diagnostic
only and do not gate current Core admission. These evidence inputs do not
expand the selected task's dependency closure.

## Required evidence

- `M2-004/current-desktop/windows-x86_64/report.json`, `validation.json`,
  and six retained native logs
- `M2-006/current-desktop/macos-arm64/report.json`, `validation.json`,
  and five retained native logs
- `current-core/qualification.json`
- `core-prerequisite-audit.json`
- `windows-x86_64/provider-result.json` and `validation.json`
- `windows-x86_64/license-bundle/manifest.json` and its digest-bound files
- `macos-arm64/provider-result.json` and `validation.json`
- `macos-arm64/license-bundle/manifest.json` and its digest-bound files
- `desktop-provider-matrix.json`
- `hosted-run.json`
- `task-check.json`
- `evidence.json`

The current-Core receipt binds the source revision, all production and
execution inputs, pinned STS archive and installed tool identities, selected
provider/adapter/capabilities/ABI, built native archive, four executed
commands, nine retained typed-digest logs, and the current installed consumer
qualification and artifact.

Raw M2 reports and text logs are source/audit inputs, not indexed PASS reports.
The sealer indexes their compatible `status: PASS` validation JSONs; the Core
audit still validates and digest-binds every raw report and log.

## Capturing current Core evidence

Capture only after the candidate source is frozen. The selected SDK archive
must be the archive pinned by `docs/references/m7-033-ci-toolchain.json` and
must match the installed STS identity; the command fails if
`WIRESTACK_BASELINE_SDK_ARCHIVE` is unset or mismatched.

```sh
python3 tools/m3_031_desktop_tls_adoption.py --root . capture-current-core \
  --revision "$SOURCE_SHA" \
  --sdk-archive "$WIRESTACK_BASELINE_SDK_ARCHIVE" \
  --output docs/evidence/M3-031/current-core/qualification.json

python3 tools/m3_031_desktop_tls_adoption.py --root . validate-current-core \
  --input docs/evidence/M3-031/current-core/qualification.json \
  --sdk-archive "$WIRESTACK_BASELINE_SDK_ARCHIVE"
```

Each capture runs the offline native provider build, architecture guard,
provider-substitution tests, and offline M7-021 installed HTTPS consumer in
that order. Full stdout/stderr logs and the consumer qualification copy are
stored under a unique `current-core/runs/<run-id>/` directory. Verification
recomputes source/execution/SDK/platform bindings, checks all command receipts
and log digests, reruns header and archive-symbol checks, validates the
retained installed qualification and smoke result, and checks artifact bytes.
The canonical PASS receipt is atomically replaced only after all checks pass;
a failed run is saved separately and cannot replace a previous receipt.
`audit-core` and `aggregate` revalidate the canonical current-Core receipt;
a hand-authored `{"status":"PASS"}` audit is not accepted.

`release: NOT_QUALIFIED` remains the development-baseline disposition. This
consumer proof does not qualify a release or substitute for a separate release
security review.

The [prefreeze tooling regression](current-core/maintenance/regression.json)
records 28 passing unit cases after correcting package/project summary parsing
and the synthetic Linux fixture. Required substitution cases must each pass;
unrelated cases omitted by the class filter are not required-case skips.
These fixture results do not establish native Core or desktop qualification.

## Historical hosted provider evidence

Earlier STS provider runs `41779297210` at `59e0fcf4`, `41698821216` at
`6c5eb96e` and `41773758417` at `e0cc7f4e` remain historical qualifications.

The retained GitHub Actions run
[`33461712135`](https://github.com/lIlIIlIll/Wirestack/actions/runs/33461712135)
executed Windows Server 2025 x86_64 and macOS 15 arm64 jobs at revision
`6c683a51b782d6fd0a10b11c59cb75d9bc9a99d2`. It recorded pinned AWS-LC 5.5.0,
schema-v11 PoCs, the required capability results, external-signing handshakes,
TLS 1.2/1.3 resumption, cleanup cycles, and retained license bundles.

These files remain useful for historical provenance and integrity checks. The
M3-030 reports are checked for task/report identity, complete inventory,
digests and their historical source digests; semantic contents are not current
Core qualification. If integrity verification fails, `audit-core` classifies
the result as a `HISTORICAL` diagnostic with `integrity_status` `STALE` or
`FAIL`, plus the precise code and detail, and continues to current Core and
direct M2 checks. A diagnostic is included in a returned audit only when those
other mandatory checks pass; it never substitutes for current Core or M2 proof.

The checked-in M3-030 bundle currently has a historical digest inconsistency.
The index records source revision
`38b58ec2fbaa0779011a70992e86ffc4bbd88e17`; that revision does not contain
`task-check.json`. The sole evidence-index commit is
`04d2f4e508300d0030e7bf63fc369e15a3c841d6`. At that commit the report's
SHA-256 is
`a8dadb0ba0be7664f499cf1bc70d447de5e5d13c73d40fdb799b1979f4976c08`, while
the original index records
`20d8509d3104369903e074044dde893b4ed18622ef47d4acb9bc87850b505610`.
The historical bytes and index are not rewritten or reconstructed; M3-030's
status remains unchanged.

## Current direct M2 evidence boundary

M3-031 consumes only fresh source-bound desktop resolver evidence:

- `M2-004/current-desktop/windows-x86_64/report.json` and `validation.json`
- `M2-006/current-desktop/macos-arm64/report.json` and `validation.json`

Each pair must validate at the frozen M3 source revision with the platform's
pinned STS SDK, exact current source inventory, native resolver cases, and
retained typed-digest logs. The SDK identity is tied to the checked-in
`docs/references/m2-004-sts-sdk.json` or
`docs/references/m2-006-sts-sdk.json` pin through the shared STS identity
helper. M3 independently verifies the report/validation digests and every
source and log byte against the current tree before admitting the evidence.

The legacy generic M2 evidence indexes and reports remain unchanged and are
not used as current resolver proof. M3-031 does not require global M2 task
statuses to be COMPLETE, consume M2-006 iOS evidence, or promote M2 status.
Those broader acceptance conditions remain with their owning tasks.

The existing M2-004 and M2-006 global status rows remain COMPLETE, but their
older status labels and generic evidence indexes do not satisfy these direct
current-report requirements. Both checked-in STS archive pins have been
matched to their archive bytes; that verifies SDK identity only and does not
execute either native resolver gate or produce its current report pair. The
fresh current-desktop report pairs are not produced by the M3-031
implementation or its synthetic tests. Until authorized Windows and macOS
native workflows capture and validate both pairs at the frozen source
revision, the current adoption audit remains BLOCKED and no native resolver
PASS is claimed. The M3-030 historical index and report bytes remain
untouched; their integrity errors remain separate HISTORICAL diagnostics.

## Remaining boundaries

- The audit covers only the desktop-applicable Core projection. It records
  global six-platform and mobile conditions as `NOT_EVALUATED`, never `PASS`.
- Historical M3 task statuses are unchanged.
- M3-014, M3-015, M3-019 and M3-020 own production desktop trust and
  non-exportable-key adapters.
- No iOS/Android/Harmony device, one-hour profile, or 86,400-second soak is
  implied by this task.
