# M8-001 evidence

Status: COMPLETE. Linux contracts, native consumers and documentation pass
qualification with terminal-close idempotence and native abort ownership.

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
network suite passed 14/14 before the fourth-review additions. Native datagram
adapters and their I/O qualification remain M8-002/M8-003 work, not simulated success here.

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

The fourth review rejects nonempty wrong-direction I/O after half-close with
structured `Closed` errors without disabling the opposite direction. Empty
buffers remain no-I/O operations. A deterministic final-direction shutdown race
failed before repair (18 passed, one failed) and passed afterward (19/19): I/O
woken by graceful shutdown must not change the final state to `Failed`.

Sealing now requires an actual local Git commit whose source tree matches all
manifest inputs. The tooling suite passed 33/33; the real CLI rejected both a
fictional commit and source changes absent from the candidate, without writing
an evidence index. Verification now also resolves the recorded commit and checks
each sealed source digest against its tree before checking working-tree drift.
It remains offline: missing candidate commits or blobs fail closed rather than
triggering a fetch. Source candidates must remain reachable in published history;
this PR uses a merge commit rather than squashing away its qualified candidate.
The earlier seal-path commands and raw logs remain in
[`review-boundaries.json`](review-boundaries.json).

The first refreshed task run passed seven commands but timed out during
documentation generation at 300 seconds. The task now uses the established
M7-033 documentation timeout of 1,800 seconds; generation and coverage
requirements are unchanged.

The fifth review restores task-total validation as a derived invariant rather
than fixed numeric expectations. A corrupted published total passed the former
three-test suite but fails the restored check; the actual graph passes all four
tests and agrees with the published 208 release tasks and 229 recorded tasks.

`readExact` now adds missing captured endpoint diagnostics while preserving
supplied endpoints and structured error fields. The two endpoint regressions
failed before repair (20 passed, two failed) and the network suite passes 22/22
afterward. A real TCP peer sent one byte then FIN; the consumer requested two
bytes and observed `UnexpectedEof` with the partial byte and both captured
endpoints intact. See [`review-fifth.json`](review-fifth.json) and
[`native-consumer.json`](native-consumer.json).

The sixth review keeps the write direction usable after short-read EOF,
retains captured diagnostics across all six I/O methods, and maps unclassified
close failures to `System` / `TransportClose` / `SystemFailure` with the original
cause and `Failed` lifecycle. Existing structured close errors are preserved.
All three reproduced failures are recorded in [`review-sixth.json`](review-sixth.json):
20 cases passed and three failed before repair; all 23 passed afterward.
The native peer now half-closes its write direction and then receives `after`
from the same consumer stream following `UnexpectedEof`. Close-error evidence
uses deterministic fault injection, not a forced native OS close failure.

The seventh review consolidates all ten public socket exception boundaries into
one mapper. Unknown failures retain operation phase, available endpoints and
the original cause. Abort failures retain `Aborted`. The native adapter records
whether cancellation won the first close; a cancelled context no longer
borrows ownership from an unrelated graceful close.

Three added regression cases failed before repair (23 passed, three failed).
All 26 passed afterward. A further real TCP cancellation case passes, bringing
the network suite to 27/27. A separate warmed consumer ran with its descriptor
limit reduced to zero: the old source leaked `SocketException`, while the fix
returns structured connect diagnostics. See [`review-seventh.json`](review-seventh.json).
No SDK source modification or injected constructor exception was used.

The eighth review checks provenance during verification as well as sealing.
Three real-Git regressions failed before repair; all 37 tooling tests pass after
repair. Fictitious and unrelated candidate revisions are rejected directly.

Stopped close contexts previously disconnected two live TCP streams without an
error. Both now retain the open stream, return structured diagnostics and allow
the peer to receive data. Once close is admitted, cancellation/deadline bounds
the caller's wait while cleanup retains ownership. Late success, failure and
concurrent abort remain distinct. Six new network cases fail on the baseline
(two assertion failures and four bounded join timeouts); all 33 pass afterward,
including normalization of a failing caller-supplied clock. See
[`review-eighth.json`](review-eighth.json). Cleanup in the guide uses `close()`,
not an exhausted operation context.

The ninth review requires terminal close calls to bypass stopped contexts and
requires `Aborted` to reflect the first native close owner. A graceful native
close is not upgraded or interrupted by a later abort request. The generalized
ownership observer replaces the cancellation-only observer; no alias is kept.
Both final network regressions fail on the prior source; all 35 network cases
pass after repair. Native adapter tests pass 34 cases with 17 existing performance
exclusions. A separate two-case real-native probe also fails before repair and
passes afterward. Its gate holds the wrapper return after native close, not an
SDK close call; no native interruption is claimed. Throwaway probe source was
removed. The initial baseline setup failure and validated native-cache restoration
are retained separately in [`review-ninth.json`](review-ninth.json).

## Acceptance

All eight task commands pass with STS 1.1.3 and pinned cjdoc 0.7.2. The canonical
check passes 626 Cangjie tests with 23 performance-tagged exclusions and no
errors/failures. Network tests pass 35/35, tooling tests 37/37 and repository
regressions 70/70. Final task-specific fast-check reports accompany the seal.
The first full-gate attempt lacked an ignored M7-021 release fixture; restoring
the exact previously qualified artifact made the gate pass. The initial failure,
artifact digest and retry are retained in `review-eighth.json`; no additional tests were excluded.

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
The final publication is based on qualified main revision
`913a75defb3bbaa15e117e642d532c8ae6a1876c`. Review checkpoints are consolidated
into an implementation commit followed by its commit-bound evidence seal.

No privileged raw I/O, non-Linux execution, later protocol integration,
one-hour SSE or final 86,400-second soak is claimed.
