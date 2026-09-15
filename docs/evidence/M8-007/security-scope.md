# M8-007 independent security review scope

This package requests a current-source security review of the Linux x86_64 glibc release after M8-001 through M8-006. The review covers source code, native boundaries, installation, parser mutation results, and supply-chain evidence. The formal 86,400-second soak and production signature verification are separate final gates. A passing source review does not attest that those gates have completed.

## Threat model and architecture

Remote peers control network input. Applications choose endpoints, trust policy, credentials, extension hooks, and resource limits. Build-time provider selection and SDK installation are trusted local inputs. The reviewer must distinguish a malformed remote message from a caller-supplied local policy.

Repository administrators control release policy. Other collaborators are outside the release-approval authority. Archive metadata and payload must pass the bounded reader before installation.

The public packages are `wirestack`, `wirestack.net`, `wirestack.tls`, and `wirestack.http`. Protocol state machines and provider bindings remain internal. Review the [threat model](../../security/threat-model.md) against the current source rather than treating an older release report as current proof.

The review must cover supply chain, certificate identity, private keys, TLS protocol behavior, lifecycle and cancellation, DNS and proxy routing, HTTP/1 request smuggling, HTTP/2 and HPACK, resource bounds, pool isolation, sensitive data, native C ABI behavior, Linux platform assumptions, and release evidence.

## Provider and native C ABI

The shipped native components are the AWS-LC TLS provider, Linux resolver bridge, and Linux HTTP filesystem bridge. Their archives and embedded manifests are enumerated in `native-rebuild.json` and checked against the installed artifact. Source pins, compiler inputs, and archive digests must agree. The release collector rejects test-only key logging and system OpenSSL loader dependencies.

Inspect `native/tls/aws_lc/wirestack_tls_provider.c`, its header and ABI contract, `native/resolver/linux`, and `native/http_files`. Check argument lengths, pointer ownership, callback lifetime, error conversion, terminal operations, and cleanup on partial failure. An embedded manifest alone is not proof that an archive contains its declared bytes.

## Parsers and resource limits

Inspect the DNS parser and resolver policy, HTTP/1 framing, HTTP/2 frame processing and HPACK, cookies and public suffix handling, multipart input, and WebSocket framing. Check malformed lengths, duplicate or conflicting fields, compression state, stream ownership, cancellation, and bounded retained state.

The fresh parser campaign uses `tools/gates/campaigns/m7-023-linux-fuzz.json`. M8-007 binds its execution to the qualification, all Cangjie source and test files, and the native build. Its ten targets do not imply exhaustive fuzz coverage of every public API or protocol extension.

The release archive reader limits each member to 8 MiB, decompressed bytes and expanded payload to 64 MiB each, and tar member headers to 4,096. PAX and GNU long-name or long-link records have an 8 KiB limit before metadata expansion. Global and effective per-member PAX dictionaries permit at most 128 fields. GNU sparse formats are rejected before their maps expand. Logical member sizes are checked again before extraction. These input limits are not a measured Python heap ceiling.

## Keys, trust, and sensitive data

Review certificate identity and hostname checks, explicit trust configuration, immutable TLS contexts, context replacement, versioned resumption state, and external signer and decryptor callbacks. Public contexts must not expose the adopted raw-RSA decryptor service. Callback arguments and failures must preserve the documented ownership and security boundary.

`KeyLogSink` is a test-provider capability. Production builds exclude that capability. Inspect errors, logs, evidence, and package inventory for private keys, TLS secrets, and unintended sensitive payloads. Source fixtures are not production credentials.

## Lifecycle, routing, and isolation

Trace shared cancellation and total deadlines through connection establishment, DNS family aggregation and failover, request handling, response bodies, HTTP/2 push, and shutdown. Check that terminal state prevents new work without discarding required joins or cleanup. Check peer and local endpoint diagnostics without reclassifying admitted operations as safely retryable.

Review pool partitioning and ownership across origins, TLS contexts, proxy configuration, and application hooks. A successful local example does not prove isolation under adversarial reuse or cancellation races.

## Review regression evidence

`runtime-review-controls.json` binds the complete HTTP/1, TLS, and net test suites to their source files and captured output. The original baseline reproduces the oversized fixed-length request, nonreusable TLS response completion, unpublished HTTP/2 admission, three TLS pump deadline/cancellation cases, expired close admission, cancelled registration cleanup, and the peer-waiting terminal-cleanup budget loss. The native TCP case separately binds the exact `c0f13f575eae4ebce07a5ff17add0758f8fca561` connection source. It requires a timed-out close to terminate an existing TCP read and release the engine without peer assistance. Its controlled TLS engine isolates scheduling and ownership; it is not a cryptographic TLS-handshake test. Terminal cleanup keeps the caller's own context while it is live and, once that budget stops graceful cleanup, claims the transport by immediate abort with the matching reason instead of handing a peer-waiting transport a reset deadline.

The intermediate TLS correction also admitted close before registering cancellation outside its cleanup block. `reproductions/tls-close-registration-before.json` and the adjacent source snapshot retain the failure when an already-cancelled token invokes a throwing transport abort. The current runtime verifier requires that exact negative case and its successful execution in the corrected TLS suite.

`soak-owner-controls.json` demonstrates that the baseline accepted the historical literal-owner log and that the current parser rejects that schema. Its corrected suite also rejects growing weak-owner series, active response ownership at idle checkpoints, unbalanced pool leases, and retained terminal transport or cancellation owners.

The soak measures pool callbacks, response closure, application and server Futures, wrapped transport I/O, weak transport references, and weak cancellation sentinels rooted by retained typed handles. Weak-reference liveness is not an active-registration count: [eager cleanup does not guarantee immediate reclamation](https://955work.icu/dev/std/std/ref/ref_package_api/ref_package_enums.html#eager). Weak-owner series therefore use growth and monotonicity gates; active application owners must be zero at checkpoints, and terminal owners must be zero before the process exits. Process and heap trends complement these observations rather than replacing them.

`reproductions/measured-owner-preflight.json` retains the failed initial measurement gate. That gate incorrectly required every sampled weak sentinel to be absent and used a socket-growth limit as an absolute wrapper-count limit. It is diagnostic evidence, not a passing preflight or formal soak.

`reproductions/measured-owner-preflight-60s-growth.json` retains a second failed preflight on the registration-corrected artifact. Its weak cancellation series ranged from one to six, but the final median exceeded the initial median by three against the unchanged limit of two. Workload, process, heap, and terminal cleanup checks passed. A 600-second measurement uses the same limits and sampling interval, with larger median windows; it does not replace or relabel the failed short run.

`archive-review-controls.json` binds seven archive rejection cases to baseline `14a9925dd78ded4f5d99eb8aa70c34f676404f3c`, the corrected reader, and digest-checked command output. The suite accepts an exact 8 MiB member and 128 cumulative PAX fields, rejects the next field, and rejects all four GNU sparse encodings. A separate allocation probe records the cumulative-metadata growth in the first correction and its early rejection after the field limit.

The first formal run used that baseline and stopped after the archive finding. `reproductions/formal-soak-14a9925/interrupted.json` retains its frozen inputs and partial workload output as `INCOMPLETE`. It supplies no formal duration credit.

`build-output-controls.json` binds three real compiler-process controls to `8a6039051dd46e5c42c57f7debbe748ae52c266d` and the corrected capture. Success and failure retain at most 16 KiB in a report or exception while streaming complete decoded diagnostics to the parent stderr log. The invalid-UTF-8 case also checks the encoded excerpt bound after replacement-character expansion.

Cancellation and transport observation tables each permit at most 1,024 references, independently of sampling frequency. Cancellation admission may collect and recheck for up to two seconds, then rejects excess live ownership. Transport admission prunes reclaimed references and rejects a full table before connecting; a concurrent admission failure aborts the newly created transport. Neither path evicts a live reference to preserve a passing measurement.

`reproductions/owner-registry-before.json` and `owner-registry-after.json` bind the baseline and corrected source, shared fixture, derived consumer, artifact, SDK invocation, and raw commands. The consumer adds a read-only synchronized slot observer. It exercises 4,096 claims without sampling and full tables with 1,024 strongly retained cancellation sentinels or closed transports. `blackBox` keeps those intended roots observable through the checks. Earlier single-GC and weak-observer attempts remain diagnostic records, not claims of an SDK defect or sufficient proof of table occupancy.

The bounded-owner preflight completed 600 seconds with a 60-second application sampling interval, 5,846 cycles, maximum cancellation latency 18.493331 milliseconds, and zero terminal owners. It ran on the corrected `5896572753484b3f64903b2b4ccc4f0f471ddab33ef034f5c3b1bb1c3d509669` artifact under `1.3.0-alpha.20260911010036`, selected through `$HOME/cangjie_sdk/daily`. It supplies no formal duration credit.

## Signing authority

Review the attestation workflow and `tools/m8_007_signing_authorization.py` against `linux_x86_64/signing-authorization.json`. The live policy restricts signing-tag creation to repository administrators and blocks tag updates and deletion. Both workflow jobs require the protected `m8-007-release` environment and the sole release-owner reviewer. Self-review is allowed for that owner; administrator bypass is disabled.

The pre-soak policy captures no approved SHA. An explicit post-soak approval selects a committed full SHA, narrows the deployment policy to its exact signing tag, and sets the protected environment variable. Runtime checks and checkout use that SHA. Final verification takes its expected SHA from the separate approval record, not the hosted report.

`hosted-source-controls.json` reproduces source substitution, omitted signing or formal files, removed committed inputs, and weakened task contracts. Corrected verification rejects all six controls. Cryptographic verification is stubbed successful where the test isolates source selection or archival acceptance. The frozen and approved task blobs allow only additive `source_paths`; signed qualification inputs retain byte identity. No non-administrator enforcement probe was run because no such credential is available.

## Release evidence and environment

`qualification.json` identifies the actual compiler, package manager, platform, artifact bytes, complete installed-consumer build output, and dynamic dependency scan. `api-inventory.json` is a current declaration inventory, not a promise of compatibility with a previous binary release. The SPDX SBOM and native manifests describe the same artifact.

The independent reviewer must inspect the source and audit the evidence. Schema validation only checks the reviewer's declaration of independence. A process-isolated agent must disclose shared model or organizational context and must not claim external human independence.

Historical M7 evidence does not satisfy a current M8-007 gate. The review index uses the dedicated M8-007 reports. The source review package deliberately excludes the final soak result and hosted signature result so the source review can finish before those gates without a circular evidence dependency.

## Reproduction

From the checkout root, with the configured Cangjie SDK and pinned provider source, the maintained commands are:

```sh
python3 tools/m8_007_final_release.py prepare
python3 tools/m8_007_final_release.py fuzz
python3 tools/m8_007_final_release.py prepare-security
```

`prepare-security` produces the current evidence index, validates the package, and writes an independent review request. It does not create a passing review. The reviewer authors `independent-review.json`; `review-report` validates that report against the unchanged request and package.

## Known limitations

The qualified platform is Linux x86_64 glibc. Other operating systems, architectures, and musl are outside this release claim. The release remains pre-1.0 and does not assert backward binary compatibility. Native SDK restrictions recorded in the public network API remain in force.

Package and license validation checks exact deliverables and declared metadata. It is not a legal opinion. A finite mutation campaign or soak does not prove the absence of defects. Production release acceptance requires the separate formal soak and authenticated artifact, SBOM, and qualified manifest signatures.
