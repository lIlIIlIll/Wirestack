# M8-007 independent security review scope

This package requests a current-source security review of the Linux x86_64 glibc release after M8-001 through M8-006. The review covers source code, native boundaries, installation, parser mutation results, and supply-chain evidence. The formal 86,400-second soak and production signature verification are separate final gates. A passing source review does not attest that those gates have completed.

## Threat model and architecture

Remote peers control network input. Applications choose endpoints, trust policy, credentials, extension hooks, and resource limits. Build-time provider selection and SDK installation are trusted local inputs. The reviewer must distinguish a malformed remote message from a caller-supplied local policy.

The public packages are `wirestack`, `wirestack.net`, `wirestack.tls`, and `wirestack.http`. Protocol state machines and provider bindings remain internal. Review the [threat model](../../security/threat-model.md) against the current source rather than treating an older release report as current proof.

The review must cover supply chain, certificate identity, private keys, TLS protocol behavior, lifecycle and cancellation, DNS and proxy routing, HTTP/1 request smuggling, HTTP/2 and HPACK, resource bounds, pool isolation, sensitive data, native C ABI behavior, Linux platform assumptions, and release evidence.

## Provider and native C ABI

The shipped native components are the AWS-LC TLS provider, Linux resolver bridge, and Linux HTTP filesystem bridge. Their archives and embedded manifests are enumerated in `native-rebuild.json` and checked against the installed artifact. Source pins, compiler inputs, and archive digests must agree. The release collector rejects test-only key logging and system OpenSSL loader dependencies.

Inspect `native/tls/aws_lc/wirestack_tls_provider.c`, its header and ABI contract, `native/resolver/linux`, and `native/http_files`. Check argument lengths, pointer ownership, callback lifetime, error conversion, terminal operations, and cleanup on partial failure. An embedded manifest alone is not proof that an archive contains its declared bytes.

## Parsers and resource limits

Inspect the DNS parser and resolver policy, HTTP/1 framing, HTTP/2 frame processing and HPACK, cookies and public suffix handling, multipart input, and WebSocket framing. Check malformed lengths, duplicate or conflicting fields, compression state, stream ownership, cancellation, and bounded retained state.

The fresh parser campaign uses `tools/gates/campaigns/m7-023-linux-fuzz.json`. M8-007 binds its execution to the qualification, all Cangjie source and test files, and the native build. Its ten targets do not imply exhaustive fuzz coverage of every public API or protocol extension.

## Keys, trust, and sensitive data

Review certificate identity and hostname checks, explicit trust configuration, immutable TLS contexts, context replacement, versioned resumption state, and external signer and decryptor callbacks. Public contexts must not expose the adopted raw-RSA decryptor service. Callback arguments and failures must preserve the documented ownership and security boundary.

`KeyLogSink` is a test-provider capability. Production builds exclude that capability. Inspect errors, logs, evidence, and package inventory for private keys, TLS secrets, and unintended sensitive payloads. Source fixtures are not production credentials.

## Lifecycle, routing, and isolation

Trace shared cancellation and total deadlines through connection establishment, DNS family aggregation and failover, request handling, response bodies, HTTP/2 push, and shutdown. Check that terminal state prevents new work without discarding required joins or cleanup. Check peer and local endpoint diagnostics without reclassifying admitted operations as safely retryable.

Review pool partitioning and ownership across origins, TLS contexts, proxy configuration, and application hooks. A successful local example does not prove isolation under adversarial reuse or cancellation races.

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
