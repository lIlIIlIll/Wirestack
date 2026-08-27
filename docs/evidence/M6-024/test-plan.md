# M6-024 test plan

## Semantics

The receiver coalesces consumed connection credit during normal reads. When the
connection receive window reaches zero, a body read that must wait can flush the
retained connection credit once. The sender grants blocked DATA permits to the
eligible stream that received a permit least recently. Both mechanisms keep the
existing queue and window bounds.

## Control-flow paths

| Path ID | Conditions and values | Runtime checks | Reachability | Notes |
| --- | --- | --- | --- | --- |
| P001 | Connection receive window is positive | Controller is open | Reachable | Keep coalescing small reads |
| P002 | Window is zero and pending credit is positive | Credit fits 31-bit window | Reachable | Emit one connection `WINDOW_UPDATE` |
| P003 | Window is zero and pending credit is zero | Controller is open | Reachable | Emit no frame |
| P004 | Several streams wait and one has never received a permit | Stream and connection credit are positive | Reachable | Select the least-recently-served stream |
| P005 | Waiting streams have equal grant order | Active stream and waiter IDs are valid | Reachable | Break ties by stream ID, then waiter order |
| P006 | A waiting stream closes or its context terminates | Cancellation, deadline, or inactive stream | Reachable | Remove the waiter and wake peers |
| P007 | One large response exhausts the real h2 connection window | TLS, flow-control, and request deadlines | Reachable on native Linux | Sibling body read triggers progress without cancellation |
| P008 | Application reads 256-byte chunks below the threshold | Receive accounting and frame encoding | Reachable | Existing coalescing count remains unchanged |

## Input and state domains

| Domain | Values |
| --- | --- |
| Pending connection credit | 0, 1, 4 KiB, half-window threshold |
| Receive window | 0, 1, 65,535 |
| Waiting streams | 1, 2, 10, 100, configured maximum |
| Sibling body size | 1 byte, 2 bytes, one frame |
| Stream state | Active, flow-stalled, closed, cancelled, deadline exceeded |
| Grant history | Never served, served once, served repeatedly, equal order |

## Semantic scenarios

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S001 | 4 KiB consumed | Window zero, pending credit 4 KiB | P002 | One connection update returns exactly 4 KiB | Frame scope, increment, available window, second flush empty | Regression | P0 |
| S002 | Repeated 256-byte reads | Window remains positive until the threshold | P001,P008 | Reads retain the existing coalescing policy | Update count stays two for 32 KiB | Boundary | P0 |
| S003 | Large waiter plus new sibling waiter | Large stream was served most recently | P004 | Sibling gets the next permit | Permit stream and byte count match sibling | Regression | P0 |
| S004 | Ten or one hundred sibling waiters | New streams have no grant history | P004,P005 | Every sibling gets a permit before the large stream reacquires remaining credit | Unique completed sibling count and bounded permits | Concurrency | P0 |
| S005 | Closed or cancelled waiter | Waiter is registered | P006 | Cleanup removes the waiter and releases capacity | Terminal error, waiter count, permit count | Lifecycle | P1 |
| S006 | Real 256-KiB response plus 2-byte siblings | First body consumed by 4 KiB and remains open | P007 | Siblings complete on the same connection without cancelling the first stream | Body bytes, protocol, deadline, first body still open | Platform,regression | P0 |
| S007 | No pending credit | Window zero | P003 | Flush is a no-op | No frame and no accounting change | Boundary | P1 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
| --- | --- | --- | --- | --- | --- | --- |
| T001 | S001,S007 | P002,P003 | Exhaust receive window, consume 4 KiB, flush twice | One exact update, then none | Frame stream ID, increment, receive window | Minimal unit |
| T002 | S002 | P001,P008 | 128 reads of 256 bytes | Existing two-frame coalescing remains | Update count and final windows | Regression unit |
| T003 | S003,S005 | P004,P006 | Two stalled reservation tasks and one credit update | Sibling wins, cancellation cleans the remaining waiter | Permit owner, terminal state, counts | Concurrency unit |
| T004 | S004 | P004,P005 | One served large stream plus 100 two-byte sibling waiters | All siblings receive permits before the large stream | Completion order, bytes, bounds | Strengthened unit |
| T005 | S006 | P007 | Real TLS loopback with one slow response and 1/10/100 siblings | Every sibling returns `ok` without first-stream cancellation | Version, body, completion deadline, connection reuse | Public regression |
| T006 | S006 | P007 | 100 repeated native Linux runs | No timeout, abort, leak, or duplicate completion | Exit status and retained raw output | Race profile |

## Evidence gaps

- No coverage, mutation, or fuzz artifact exists for M6-024 yet.
- Native execution is available only for glibc Linux in this task.
- The implementation must retain raw latency and flow-control-stall output
  before M6-024 can become COMPLETE.
