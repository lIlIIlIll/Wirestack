# M8-003 Unix socket qualification plan

This plan covers the Linux x86_64 glibc std.net backend. The shared endpoint model retains arbitrary abstract-name bytes. Outgoing abstract names are supported only at exactly 107 valid UTF-8 bytes: the SDK otherwise changes their identity through native padding or rejects Unicode conversion. Privileged raw I/O has no installed adapter.

## Semantics and ownership

`UnixStream` and `UnixListener` provide synchronous stream operations under the existing absolute operation context. Accept cancellation leaves the listener reusable. An active stream cancellation owns terminal disposal. One read and one write may overlap.

`UnixDatagramSocket` implements the capability-scoped `DatagramSocket` contract. Explicit `sendTo` is atomic, receive results own their bytes, and capacity is bounded to 1 through 65,507. `connect` installs native incoming-peer filtering. Connected `send` is Unsupported because the SDK re-resolves the selected address and can deliver to a replacement socket. Empty receives remain datagrams; empty sends are also rejected before I/O. Both rejection paths leave the socket reusable.

Closing pathname sockets releases descriptors but leaves filesystem socket nodes for their owner to remove. Qualification uses a private temporary directory. Supported abstract names contain exactly 107 bytes, including an embedded NUL and a multibyte UTF-8 character.

## Control-flow paths

| Path ID | Conditions and values | Runtime checks | Reachability | Notes |
|---|---|---|---|---|
| P001 | Pathname or supported abstract endpoint reaches native bind/connect | Named form, exact 107-byte outgoing abstract profile, valid UTF-8 | Linux native | Compare actual local and remote names |
| P002 | Unnamed destination or unsupported outgoing byte name | InvalidState or Unsupported before socket I/O | Public error path | Model construction must still retain arbitrary bytes |
| P003 | Stream accepts/connects, transfers partial chunks, reaches EOF | Exact/all loops and stable EOF | Linux native | EOF must not remove write capability |
| P004 | Accept waiter stops, then another accept is admitted | Same-direction admission, cancellation, late completion | Native plus coordinator branches | Listener stays open and accepts a real later connection |
| P005 | Active stream read stops by cancellation or graceful close | Native wait admission and close ownership | Linux native | Opposite-direction write and endpoint-bearing error |
| P006 | Datagram receive has zero, exact, truncated, or maximum payload | Owned result, packet boundary, source address | Linux native | No stream-like partial success |
| P007 | Datagram connects, rejects unsupported sends, receives only selected peer | Exclusive connect, send and receive admission | Linux native | Explicit sendTo after rejection proves reuse |
| P008 | Active datagram receive stops or expires | Cancellation, deadline, graceful disposal | Linux native | No abandoned descriptor or replay-safe admitted send claim |
| P009 | Raw open is requested for each modeled domain | Explicit Unsupported | Public error path | No privileged native support claimed |
| P010 | Repeated creation/disposal and terminal close | First native close owner, stopped-context idempotence | Linux native | Inspect descriptors while consumer remains alive |
| P011 | Stream output fills the native send buffer | Native sendto EAGAIN, absolute deadline, non-replayable error | Linux native | An admitted timeout cannot prove zero physical commit |
| P012 | A connected pathname is unlinked and rebound to a different socket | Connected-send capability guard, receive filtering, explicit destination | SDK negative plus guarded public native path | No implicit payload may reach the replacement |

## Input domains

- Endpoint form: pathname, exactly 107 UTF-8 abstract bytes with embedded NUL, short abstract names, non-UTF-8 abstract bytes, and unnamed. Existing M8-001 endpoint validation owns empty names, maximum name length, and pathname NUL rejection.
- Stream transfer: independent 32,768-byte payloads split into 1,021-byte writes, stable EOF, a write after EOF, and a 1 MiB backpressured write with a two-second deadline.
- Datagram payload: zero, capacity minus/plus boundary, exact capacity, and 65,507 bytes. Existing Internet regressions retain invalid-capacity and oversize contract checks after shared-core changes.
- Operation state: before admission, active, concurrent same direction, opposite direction, cancelled, deadline exceeded, gracefully closed, and abortively closed.
- Raw domain: IPv4, IPv6, AF_PACKET, and AF_NETLINK. SOCK_SEQPACKET and ancillary operations remain explicit exclusions, not exposed no-op APIs.

## Semantic scenarios

| Scenario ID | Input and pre-state | Paths | Expected behavior and required assertions | Type | Priority |
|---|---|---|---|---|---|
| S001 | Two supported address profiles, fresh sockets | P001,P003 | Independent peers exchange exact bytes and observe expected address form/name | native | P0 |
| S002 | Abstract model contains 0xFF; outgoing operation requested | P002 | Model retains bytes, SDK limitation becomes Unsupported without a live socket | regression, boundary | P0 |
| S003 | Unnamed endpoint used for bind/connect | P002 | InvalidState; accepted unbound peers still report unnamed correctly | boundary | P0 |
| S004 | Peer sends data then closes its write direction | P003 | Repeated EOF and successful local write afterward | native, lifecycle | P0 |
| S005 | Accept has reached native EAGAIN | P004 | Overlap rejected, cancellation returns, same listener accepts next connection | concurrency | P0 |
| S006 | Stream read has reached native EAGAIN | P005 | Read overlap rejected, opposite write works, cancel/close wakes with correct endpoint and state | concurrency | P0 |
| S007 | Empty, truncated, exact-size, maximum datagrams | P006 | Payload, source, truncation, and ownership assertions match each packet | boundary | P0 |
| S008 | Connected socket receives from selected and other peer | P007 | Wrong peer rejected or not delivered; selected packet arrives | native | P0 |
| S009 | Empty or connected send attempted on reusable Unix socket | P007 | Unsupported, followed by a successful atomic explicit sendTo | regression | P0 |
| S010 | Datagram receive reaches native EAGAIN | P008 | Overlap rejected, opposite send works, cancel/close wakes and owns terminal state | concurrency | P0 |
| S011 | Datagram receive deadline expires | P008 | TimedOut under the original context; explicit cleanup completes | boundary | P0 |
| S012 | Four raw domains requested | P009 | Unsupported and zero raw-descriptor creation; native raw capability BLOCKED | capability | P0 |
| S013 | 64 stream/listener and datagram creation cycles per profile | P010 | Native creation flags present and socket descriptor sets empty at both live checkpoints | resource | P0 |
| S014 | Repeated terminal close with stopped context | P005,P008,P010 | Closed/Aborted ownership retained and no renewed context failure | lifecycle | P0 |
| S015 | Stream send reaches native EAGAIN without a reading peer | P011 | TimedOut, Write category, Never retryability, native cause and Unix endpoint | regression | P0 |
| S016 | Short outgoing abstract name | P002 | Shared value retains the name; bind/connect/sendTo reject rather than append significant NUL bytes | regression | P0 |
| S017 | Independent sender uses a short abstract name containing 0xFF | P006 | Incoming source bytes remain exact despite the outgoing-address limitation | boundary | P0 |
| S018 | Selected pathname is replaced while original peer stays alive | P007,P012 | SDK misdelivery is recorded as BLOCKED; public connected send is Unsupported with no packet; filtering and explicit sendTo still work | regression, capability | P0 |

## Test-plan matrix

Command results distinguish qualified supported behavior from explicit SDK capability exclusions. A PASS on the rejection guard is not a PASS for the rejected native capability.

| Test ID | Scenario IDs | Path IDs | Command or evidence | Required assertions | Status |
|---|---|---|---|---|---|
| T001 | S001,S002,S003 | P001,P002 | Archived standalone SDK probes on pinned and daily SDKs | Byte-name behavior, actual Unicode failure, pathname disposal behavior | Observed SDK behavior only |
| T002 | S001,S003,S004,S005,S006,S007,S008,S009,S010,S011,S012,S013,S014,S015,S016,S017,S018 | P001,P002,P003,P004,P005,P006,P007,P008,P009,P010,P011,P012 | `python3 tools/m8_003_native_sockets.py` | Independent peers, exact bytes and names, EAGAIN admission, non-replayable write timeout, capability guards, flags and live descriptors | PASS; native-sockets.json |
| T003 | S002,S003,S005,S006,S007,S009,S010,S014 | P002,P004,P005,P006,P007,P008,P010 | `cjpm test src/net --no-progress --no-color` and canonical transport regression selection | Existing public socket contracts survive shared implementation changes | PASS; network-tests.json and transport-tests.json |
| T004 | S001,S012 | P001,P009 | API inventory, API compatibility review, architecture guard, documentation generation | Exported API is explicit and provider-neutral; unsupported native capabilities remain visible | PASS; API/docs/architecture reports |
| T005 | S001,S013 | P001,P010 | Canonical full repository check; separate required post-seal verification | Complete command results; committed source provenance must be checked after sealing | PASS local full gate; remote verification recorded separately |

## Evidence gaps and limits

The pinned 1.1.3 SDK and daily 1.1.0-alpha.20260829040003 both reject an outgoing abstract name containing 0xFF in `std.net.SockAddr.init`, after `UnixSocketAddress.toString` attempts Unicode conversion. This is not an arbitrary-byte native support PASS. The endpoint value model remains unchanged.

Short abstract names are also BLOCKED: native sockaddr length 110 adds significant trailing NUL bytes. Unbound datagram sources are BLOCKED because SDK receiveFrom consumes the packet then fails address conversion with socket family 0. Incoming named non-UTF-8 sources are independently verified and preserved.

The pinned SDK's UnixDatagramSocket.send also re-resolves a connected pathname. A replacement socket received the packet even after concrete SDK send dispatch replaced sendTo. The adapter therefore advertises connectedDatagramSend=false and rejects connected send; native receive filtering and explicit sendTo remain supported. This connected-send limitation was exercised on the pinned SDK, not independently on the daily SDK.

Raw I/O remains BLOCKED without a native adapter. AF_PACKET, AF_NETLINK, SOCK_SEQPACKET, and ancillary operations are excluded. No non-Linux, one-hour SSE, 86,400-second soak, line coverage, mutation, or fuzzing result is claimed by this task.
