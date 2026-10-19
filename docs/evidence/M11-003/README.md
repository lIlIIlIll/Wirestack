# M11-003 — ws/wss URL and WebSocket lifecycle acceptance

Status: **COMPLETE**. Issue: [#180](https://github.com/lIlIIlIll/Wirestack/issues/180).

Evidence kind: source-bound working-tree acceptance on native Linux x86_64 glibc. The candidate is uncommitted and **NOT_QUALIFIED**. No commit, push, PR, issue mutation, signing, upstream edit, or non-Linux qualification was performed.

## Workspace safety and dependencies

[Workspace receipt](workspace.json) and [initial status](initial-status.txt) record the pre-edit root as `<repo>`, physical branch `gitbutler/workspace`, logical branch `m11-003-websocket`, starting HEAD `d96a333e4017059dc38f62ddda03a3536c200676`, and merge base with main `00d6864f8f5dee6a5c13a5a68144135e9e9601bc`. The 193 existing dirty entries comprise 109 unstaged and 84 untracked paths; none were staged. No reset, clean, stash, rebase, amend, force push, or discard was used.

M9-001, M10-001 and M10-005 were COMPLETE with acceptance evidence before implementation. Task scope and source inventory are recorded in [the manifest](../../../tools/tasks/M11-003.json). Only the M11-003 planning row was advanced; no later task was implemented.

## Scope and API review

- Added `wirestack.http.WebSocketUrl`; `connectWebSocket` accepts only this `ws`/`wss` entry. Ordinary `HttpUrl` remains HTTP(S)-only. Reused the authority/IP/port/escape validator instead of adding a second URL parser or a compatibility overload.
- Added the bounded RFC 3986 ASCII target profile, exact original-input limit, positive/negative cases and deterministic raw/escaped-octet corpus. Invalid input performs no connector I/O.
- Moved the existing portable IP decoder into an internal root helper and added one literal-address connector path. Native IPv4/IPv6 no longer go through DNS-only `HostName`. TLS handshakers now retain DNS/IP reference identity; only DNS identity produces SNI. All affected internal consumers and the older native HTTP example were migrated.
- Retained canonical session deadline, parent/per-call cancellation, active-read-idle policy and real request/attempt/connection/HTTP2-stream correlation. Completed response-header caps do not become session lifetime. Frame contexts can shorten but cannot extend the retained budget.
- Retained one transport owner, bounded control/close behavior and exact-once terminal cleanup. Each direction has one active operation and one pending slot; excess callers receive `CapacityExceeded` before frame I/O. Default frame calls do not allocate a cancellation-token bridge or an idle admission wake registration.
- A narrow shared-gate repair changes the older gzip runner's source comparison to the repository's existing typed, fail-closed equality helper. The real extracted-source SPDX path and altered-source rejection were exercised; no historical M11-002 evidence was regenerated.

The current inventory contains **363 public declarations**, zero internal aliases, and passes owner/alias/forbidden-type checks. The historical M11-002 inventory remains intact. This pre-1.0 inventory is not an ABI or historical-compatibility guarantee.

Migration, ownership, Ping/Pong/Close, reader/writer capacity, cancellation/backpressure, heartbeat versus business progress, and possible lost/duplicate application messages are documented in [the guide](../../guides/websocket.md). No automatic heartbeat, application replay, reconnect, extension or compression was introduced.

## Acceptance and exact results

| Command / surface | Result | Evidence |
| --- | --- | --- |
| `scripts/check-task M11-003 --json --output docs/evidence/M11-003/task-gate.json` | Exit 0; all five task commands PASS, none timed out | [Task gate](task-gate.json) |
| `cjpm check` | Exit 0 | [Full stdout](logs/task-cjpm-check.stdout.log) |
| `cjpm test --target-dir target/m11-003-native --exclude-tags=Performance --parallel 1 --no-progress --no-color --timeout-each 60s` | Exit 0; 1002 passed, 28 explicitly excluded Performance cases, 0 errors, 0 failures; total 1030 | [Full native stdout](logs/task-native-websocket-and-regression.stdout.log) |
| `cjpm test --filter='*WebSocket*' --parallel 1 --no-progress --no-color --timeout-each 60s`, SDK 1.3.0-alpha.06 | Exit 0; 27 passed, 1003 filtered skips, 0 errors/failures | [Focused primary log](logs/websocket-primary.log) |
| Same filter, `--target-dir target/m11-003-sdk113`, SDK 1.1.3 | Exit 0; 27 passed, 1003 filtered skips, 0 errors/failures | [Focused SDK 1.1.3 log](logs/websocket-sdk113.log) |
| `python3 tools/m11_003_native_websocket.py`, SDK 1.3.0-alpha.06 | Exit 0; all 15 CHECK markers exactly once and final PASS marker once | [Installed report](installed/report.json) |
| Same runner with `--output docs/evidence/M11-003/installed-sdk113`, SDK 1.1.3 | Exit 0; all 15 CHECK markers exactly once and final PASS marker once | [Installed SDK 1.1.3 report](installed-sdk113/report.json) |
| Four release/supply-chain/API Python unittest modules in the manifest | Exit 0; 48 tests, OK | [Full Python stderr](logs/task-release-api-tooling.stderr.log) |
| `python3 tools/architecture_guard.py --root . --format text` | Exit 0; PASS | [Architecture log](logs/architecture.log) |
| `scripts/check-m7-032-public-api --write --json` | Exit 0; PASS | [Public API report](public-api.json) |
| `python3 tools/check_network_capabilities.py --check` | Exit 0 | [Capability log](logs/capability.log) |
| `scripts/check-docs --html --output docs/evidence/M11-003/docs/report.json`, `cjHeapSize=1GB` | Exit 0; strict deny-warnings checks and generation pass for seven packages plus combined view; 1870/1870 symbols and 947/947 parameters documented | [Strict docs report](docs/report.json) |
| Actual Chromium search/navigation | Found and opened `WebSocketUrl`; rendered `connectWebSocket(url: WebSocketUrl, ...)`; no captured page/request errors | [Browser receipt](docs/browser.json), [visual proof](docs/websocket-url.webp) |
| Isolated typed SPDX smoke | Four actual archived/installed gzip source digests match; changing an installed source is rejected; old dependency observations retained, not rerun | [Smoke receipt](logs/typed-spdx-smoke.json) |
| `git privacy-check` | Exit 0 | Recorded in [verification](verification.json) |

The installed consumer uses public imports only, builds against a fresh extracted production archive rather than the checkout, and verifies matching production source bytes before and after execution. Both SDK runs prove real H1/H2 exchanges, literal/default/explicit authority routing, TLS identity/SNI, authenticated proxy isolation, fragmented data/control/close exchange, rejection body ownership, malformed handshakes, slow-consumer backpressure, cancellation/close races and rollback. Already-open 131072-byte H2 sibling responses survive affected-session abort; a replacement connection cannot satisfy that check.

The backpressure measurement is the managed DATA ledger under an explicit 262144-byte ceiling, not a claim about total process RSS or application-owned frame memory. Default-port probes assert planned port 80/443 and actual authority, then a public connector maps to an ephemeral native listener; they do not claim privileged-port binding. Dynamic managed-byte observations are stored in the native reports, not pinned to an initial receive-window value.

`DT_NEEDED` for both installed binaries contains only `libboundscheck.so`, `libc.so.6`, `libcangjie-runtime.so` and `libm.so.6`. No OpenSSL or compression runtime dependency was added. OpenSSL is used only to create controlled test certificates.

## Failing-before and corrected-after evidence

[Original deadline failure](logs/before-deadline.log): an archived M11-002 implementation actually compiled and ran the same cleartext lifetime scenario, using its old HTTP URL entry. A one-second handshake deadline and a ten-second frame context left the reader blocked beyond a three-second observation bound; the test errored with `TimeoutException`, exit 1. The corrected native scenario passes under the retained session deadline on both SDKs.

[Original IPv6 failure archive](failed-native-ipv6.tar.gz): the installed `ws://[::1]:...` consumer failed inside DNS-only `HostName` construction. The corrected runner exercises actual direct/proxy IPv4 and IPv6, including wss IP SAN with no DNS SNI.

[Prior backpressure-fixture archive](pre-send-barrier.tar.gz): the primary SDK passed while SDK 1.1.3 exposed a reused-connection credit-coalescing assumption in the fixture. The final fixture observes the second native 32768-byte frame send in flight, its first completed frame, retained unread DATA and sender non-completion. It does not lower the backpressure requirement or change production flow control.

Compiler adapter-migration and strict-context-annotation diagnostics are retained in `logs/before-tls-lease-migration.log` and `logs/before-context-doc.log`. Final strict gates were not weakened. Durable logs normalize local paths; the native runner also normalizes loopback endpoint text to documentation addresses. This redaction does not change source/binary byte digests, marker counts, outcomes or timings.

## Files and remaining limits

Exact accepted-candidate source paths and their current typed digests are in [verification](verification.json). The manifest additionally binds ancestor-stack sources touched by the Codex review rounds; their current working-tree digests are recorded under `review_round_source_binding` in that file and add no accepted-candidate claim. Generated API projections are under `docs/api/generated/`. The implementation, regression cases, older consumer migration, installed acceptance runner, task manifest, API baseline, guides and current planning row belong to this task.

No implementation blocker remains. Limits: native Linux x86_64 glibc only; no cross-platform claim, performance qualification, release signing, committed-candidate sealing, exactly-once delivery, auto-recovery or extension/compression support. The old `connectWebSocket(HttpUrl)` entry is intentionally removed.

Suggested next READY task: **M11-004**. It was not started.
