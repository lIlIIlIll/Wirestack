# M8-001 evidence

Status: COMPLETE. PR #157 was requalified after scope and contract corrections.
Only the fresh scoped results below qualify the current source.

## Scope

- Public `wirestack.net` endpoint, lifecycle, context, option-value and capability
  contracts, with a TCP stream bridge to the existing Transport SPI.
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
network suite now passes 9/9 tests. Native datagram adapters and their I/O
qualification remain M8-002/M8-003 work, not simulated success here.

## Acceptance

All three task-specific fast commands and all eight task commands passed with
STS 1.1.3 and pinned cjdoc 0.7.2. `scripts/check` passed 597 Cangjie tests with
23 performance-tagged exclusions, zero errors and zero failures. The network
contract suite passed 9/9 without skips.

The inventory contains 260 declarations and 103 aliases. API documentation
covers all 1,089 symbols and 430 parameters. Both guide examples compiled;
the TCP example executed against a real receiver and sent exactly `hello`.
The datagram caller was compile-checked, not executed against a native adapter.

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
