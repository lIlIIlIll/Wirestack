# M8-001 evidence

Status: COMPLETE. This isolated publication reconstructs the M8-001 contract
from the cumulative workspace. Exact early source snapshots were unavailable.
The reports under `historical/` are not acceptance evidence for this source.
Fresh native tests, documentation, repository checks and the public consumer pass.

## Scope

- Public `wirestack.net` endpoint, lifecycle, context, option-value and capability
  contracts, with a TCP stream bridge to the existing Transport SPI.
- Explicit Unix/raw capability boundaries. Address construction does not prove
  native adapter support.
- Initial provider-neutral HTTP parity value and hook contracts. Client/server
  integration remains M8-005 work.
- Public API inventory, complete API documentation, negative tests and bounded
  DNS-header mutation coverage.

The publication worktree is separate from the original dirty workspace. See
`workspace-safety-publication.json` for the branch, base, platform and toolchain
commands. The original files and index are not publication inputs to Git.

## Acceptance

The three task-specific fast commands and all nine task commands passed with
STS 1.1.3 and pinned cjdoc 0.7.2. `scripts/check` passed 607 Cangjie tests with
23 performance-tagged tests excluded, zero errors and zero failures. The separate
network and HTTP commands passed 10/10 and 80/80 tests without skips.

The public-only inventory contains 279 declarations and 103 aliases. API
documentation covers all 1,160 symbols and 470 parameters. The guide's clean
consumer compiled and ran against a real IPv4 loopback receiver, which received
exactly `hello`; see [`native-consumer.json`](native-consumer.json).

Three HTTP regressions failed before repair and pass afterward: failed cookie
persistence cannot replace or evict visible credentials; longer cookie paths
precede shorter paths without reordering ties; MIME boundary validation rejects
HTTP-token bytes outside its unquoted-safe subset. The boundary test mutates all
128 ASCII bytes. See [`http-contract-reproduction.json`](http-contract-reproduction.json).

[`task-check.json`](task-check.json) records the nine task commands; individual
reports retain their raw logs. [`evidence.json`](evidence.json) binds the fresh
reports and source inputs. Diagnostic failures remain under `diagnostics/`.
The first full check lacked the historical M7-021 archive required by six M7-030
unit tests. Restoring that exact fixture made the full check pass; the archive
is not an M8 release artifact or reused M8 acceptance evidence.

The original dirty worktree/index remain separate. The publication branch merged
main at `913a75defb3bbaa15e117e642d532c8ae6a1876c`, including the qualified M7-033
prerequisite. No reset, stash, rebase or original-worktree commit was used.

M8-002 owns native TCP/UDP listener, socket options and wakeup evidence; M8-003
owns Unix/raw native capability evidence; M8-004 owns full DNS. No privileged raw
I/O, non-Linux execution, later protocol integration or long soak is claimed.
