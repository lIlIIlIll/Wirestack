# M8-005 Linux HTTP parity

Status: local qualification PASS after security review corrections. Publication and merge status are separate from local qualification.

The isolated publication checkout starts at merged M8-004 commit `b1368db964d172c4b08ef15f7132b29f7c4b59dd`. The original workspace is not modified. `evidence.json` is the canonical source-candidate and report index.

## Qualified implementation

- Bounded CookieJar storage and client integration, including default ICANN and PRIVATE public-suffix rules, protected Secure-cookie state, expiry, domain/path matching, and explicit-header precedence.
- Replayable multipart encoding, bounded incremental parsing, and Linux x86_64 glibc FileHandler download/upload through the native root-confined file bridge.
- Explicit HTTP/1.1 Upgrade ownership and uncompressed HTTP/1.1 and HTTP/2 WebSocket sessions.
- Bounded HTTP/2 push admission and caller-driven delivery. Admitted bodies run independently of parent response commitment.
- Connector, connection-pool, and service hooks integrated with existing resolver, ownership, and failure handling.

A push worker retains the parent request's cancellation links through cleanup. Reset signals cancellation without running user body cleanup on the reader or freeing a still-running worker's slot. A failed admission closes the supplied response. Parent END_STREAM completes an empty push source without requiring a body read, while queued pushes remain available.

Transferred pushed response bodies retain the originating request's cancellation token and absolute deadline after headers and parent completion. An independent parent's body retains its own context.

HTTP/2 encoded header batches remain contiguous through their final CONTINUATION frame, including blocks larger than the scheduler's control burst. An encoding or admission failure that can invalidate compression state terminates the connection. Followed redirects close the previous response and its unclaimed push source.

The [Linux HTTP guide](../../guides/http-parity-linux.md) describes public use and ownership. The [test plan](test-plan.md) maps 11 paths and 40 scenarios to 28 executed rows.

## Executed acceptance

The supported environment is Cangjie STS 1.1.3, cjdoc 0.7.2, and Linux x86_64 glibc. [task-check.json](task-check.json) records the manifest's exact commands and raw captures. Skipped cases are not counted as passes.

| Gate | Observed result |
|---|---|
| Plan, architecture, and task contract | PASS |
| `cjpm check` and `cjpm build` | Exit 0 |
| [HTTP facade tests](http-tests.json) | 108 passed, 3 skipped, zero failures |
| [HTTP protocol tests](protocol-tests.json) | HTTP/1.1: 115 passed and 3 skipped. HTTP/2: 177 passed and zero skipped. Zero failures |
| [Installed public consumer](native-http.json) | Five modes PASS |
| [Public API inventory](api-inventory.json) | 314 declarations and 110 resolved aliases |
| [cjdoc check and generation](docs-report.json) | 1,443 symbols and 689 parameters documented, both 100% |
| [Full repository check](full-check.json) | PASS. Cangjie: 758 passed, 23 skipped, zero failures |
| [Selected Python regressions](regression-tests.json) | 240 passed |
| [Pinned PSL and offline generator](public-suffix-database.json) | Source, MPL license, and generated tables agree |

The installed consumer rebuilds a release archive, extracts it outside checkout imports, and compiles the public example against that install. Its five modes cover cookies and hooks, binary multipart and files, generic HTTP/1.1 Upgrade, HTTP/1.1 WebSocket, and HTTP/2 WebSocket with push. The HTTP/2 mode receives the parent response before draining a 131,072-byte push, then checks a sibling request while the WebSocket remains open. The file mode distinguishes pre-cancellation from an expired deadline and then downloads successfully through the same FileHandler.

The API inventory and installed compile are not binary or forward-compatibility proofs. Rebuild consumers with the matching package and native libraries.

## Reproduced failures and corrections

- [cookie-secure-red.log](cookie-secure-red.log) records the valued Secure-attribute failure. Secure and HttpOnly attributes now use their attribute names regardless of an optional value. The corrected cookie suite passes in [http-review-green.log](http-review-green.log) and the final HTTP suite.
- [multipart-boundary-red.log](multipart-boundary-red.log) records an accepted separator boundary failing its own unquoted Content-Type round trip. The writer now quotes boundaries. Source and installed-consumer checks pass.
- [Client HPACK red](probes/client-hpack-red/client-hpack-red.json) records the peer remaining connected after an encoded-header failure. [Client HPACK green](probes/client-hpack-green/client-hpack-green.json) observes peer termination before explicit cleanup.
- [The integrated protocol failure](commands/20260913T132733431279Z/http-protocol-tests.stdout.log) records the no-offer push source waiting until its deadline after parent END_STREAM. [The focused correction](probes/parent-push-completion-green/parent-push-completion-green.json) executes one passing case. The final protocol suite passes all 177 HTTP/2 cases.
- [The multipart mutation red run](commands/parser-review-red/http-contract-tests.json) records an adopted response body left open after invalid metadata. Terminal `MultipartException` paths now close the decoder before rethrowing the original error. [The green run](commands/parser-review-green/http-contract-tests.json) passes all 106 HTTP cases and retains recoverable active-part rejection.
- [The security boundary red run](probes/security-boundaries-red/security-boundaries-red.json) compiles and fails two cookie cases and two pushed-body context cases. [HTTP green](commands/security-boundaries-green/http-contract-tests.json) and [protocol green](commands/security-boundaries-green/http-protocol-tests.json) pass after the corrections.
- [The PSL conversion red run](probes/public-suffix-idna-red/public-suffix-idna-red.json) records the lossy IDNA2003 conversion of `faß.test` to `fass.test`. The generator now uses lowercase NFC and lossless punycode. [Three generator regressions](probes/public-suffix-generation-green/public-suffix-generation-green.json) also cover rule operators, inline comments, and invalid labels.
- [The inherited-suffix red run](probes/inherited-suffix-red/inherited-suffix-red.json) reproduces parent-domain cookie injection across wildcard registrants and an exception's effective suffix. [The green run](probes/inherited-suffix-green/inherited-suffix-green.json) rejects those scopes while preserving valid exception-domain cookies.

Additional passing regressions cover reset during push transfer, header-only ownership, cancellation registration retention, bounded admission after parent reset, blocked-worker cleanup, duplex-handler return, valid Upgrade offer lists, and mismatched Upgrade/CONNECT calls before connector I/O. These are passing regression checks, not claims that every case was executed against the pre-fix source.

Earlier command directories retain compilation and integration failures separately from the final passing reports. Full-check repairs remove an incidental TLS-import count and exact error-message assertions, construct current temporary unit fixtures without rewriting historical reports, and use the established digest-domain boundaries for archive payloads.

The historical M7-024 HTTP/2 performance record correctly rejects the changed production source digest. Its unit test now checks that fail-closed result. No old performance report is relabeled as qualification for M8-005.

## Bounded parser mutation coverage

The [captured corpus run](probes/parser-mutation-corpus/parser-mutation-corpus.json) uses `--show-all-output` to retain actual execution counts:

| Parser | Executed corpus | Observable checks |
|---|---|---|
| Set-Cookie | 4,068 mutations: 2,162 accepted and 1,906 rejected, plus independent syntax and scope controls | Bounded injection-free headers, unrelated-host rejection, host-only and path boundaries, and Secure transport scope |
| Multipart | 4,937 cases across four read splits, 19,748 executions. Four limit cases add 16 executions | Exact binary and metadata preservation, split-independent typed outcomes, finite reads, and adopted-source closure |
| WebSocket | 27 protocol anchors and 876 generated mutations across four read splits, 3,612 executions | Frame traces, typed errors, deterministic control replies, frame/message limits, and exclusive terminal ownership |

These deterministic mutation tests run in the ordinary HTTP suite. They are bounded regression coverage, not a claim of exhaustive fuzzing or a coverage percentage.

## Public suffix source and licensing

The bundled list comes from upstream revision `3955e3ec29b94c3cca7bd4509c5f14a7c0959e26`. The [provenance file](../../../third_party/public_suffix/source.json) records the source URL and exact SHA-256. The list, MPL-2.0 license, generator, and generated source are included in the release. The library does not download updates at runtime.

## Evidence boundaries

No WebSocket compression, ws/wss URL parsing, browser cookie conformance, non-Linux FileHandler, interruption of an in-kernel blocking filesystem syscall, performance percentile, release signature, or final 86,400-second soak is claimed here. M8-006 and M8-007 require their own implementation and qualification. M8-007 must run the final candidate for the full required soak duration.

The final seal binds the exact source commit, task inputs, required reports, and retained raw logs. Verification must resolve that commit locally and report no stale paths. Qualification alone does not publish or merge this task.
