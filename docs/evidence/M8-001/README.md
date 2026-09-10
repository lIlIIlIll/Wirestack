# M8-001 evidence

Status: COMPLETE. All review corrections have fresh scoped verification.
The source candidate is committed before the final evidence seal.

## Scope

- Shared `wirestack` Internet/Unix endpoint values and `wirestack.net`
  lifecycle, context, option-value and capability contracts, with a TCP stream
  bridge to the existing Transport SPI.
- `DatagramSocket` connect/send/sendTo/receive/lifecycle operations under one
  absolute context, message atomicity, bounded payloads and explicit truncation.
- Distinct Unix pathname/abstract/unnamed values and fail-closed raw capabilities.
- Public-only inventory, API documentation, negative tests and native TCP consumer.

HTTP parity values, hooks, implementation and evidence belong to M8-005. DNS
wire parsing belongs to M8-004. Both were removed from this task, including their
public inventory entries. Their earlier source remains recoverable at commit
`115c5c86cc661f553c96bfcc9a614fbc2003215a`; it is not current M8-001 acceptance.

## Review corrections

The package-wide low-level socket guard exception was removed. A regression
rejects `StreamingSocket` in `wirestack.net` while allowing Wirestack's own
`RawSocket` declaration. It failed before repair and passes afterward.

Datagram result construction rejects payloads above 65,507 bytes and owns its
receive data. The oversized-result regression failed before repair; the scoped
network suite now passes 14/14 tests. Native datagram adapters and their I/O
qualification remain M8-002/M8-003 work, not simulated success here.

The second review retains graceful close, abort, failure and directional
half-close states; requires an explicit raw protocol; rejects pathname NUL
without changing abstract bytes; and captures a clean 40-hex Git revision.
The project owner approved updating PRD §16.1 to shared `NetworkEndpoint`
error fields. All Internet error boundaries migrated; Unix metadata is lossless.
See [`review-round-two.json`](review-round-two.json): 26 revision-tooling tests,
13 network tests and 4 selected error tests passed. The latter command excluded
79 unrelated cases by filter; the canonical gate subsequently passed all 83
transport tests.

The third review reproduced cancellation closing the delegate while the stream
still reported `Open`. [`review-cancellation.json`](review-cancellation.json)
records the failing regression and the 14/14 post-fix result. A pre-cancelled
operation leaves an untouched transport open; cancellation that closed it retains
`Aborted`, including after later `close` calls, without changing the error code.

## Acceptance

All three task-specific fast commands and all eight task commands passed with
STS 1.1.3 and pinned cjdoc 0.7.2. `scripts/check` passed 604 Cangjie tests with
23 performance-tagged exclusions, zero errors and zero failures. The network
contract suite passed 14/14 without skips.

The inventory contains 260 declarations and 103 aliases. API documentation
covers all 1,093 symbols and 430 parameters. All three guide examples compiled;
the TCP example executed against a real receiver and sent exactly `hello`.
The Unix error helper executed and retained bytes `00 ff 01`; this is not native
Unix socket I/O. The datagram caller was compile-checked only.

[`task-check.json`](task-check.json) retains exact commands and checksummed raw
logs; [`review-corrections.json`](review-corrections.json) records the reproduced
defects and scope removals. The native inventory report keeps its original
`decision` schema; its successful command is sealed, and the raw report is a
fingerprinted verification input. Prior mixed-scope reports were removed from
this publication, not relabeled as current evidence.

The publication worktree is separate from the original dirty workspace and
index. See [`workspace-safety-publication.json`](workspace-safety-publication.json).
The branch incorporates qualified main revision
`913a75defb3bbaa15e117e642d532c8ae6a1876c` without reset, stash or rebase.

No privileged raw I/O, non-Linux execution, later protocol integration,
one-hour SSE or final 86,400-second soak is claimed.
