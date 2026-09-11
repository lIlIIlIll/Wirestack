# M8-002 test plan: bounded Linux TCP and UDP

Scope: Linux x86_64 glibc, resolved IPv4/IPv6 Internet endpoints, public
`wirestack.net.TcpListener`, `TcpStream` and `UdpSocket`. Native Unix/raw I/O,
DNS wire transport, HTTP/TLS replacement and release soak remain owned by
M8-003 through M8-007. This plan does not claim coverage percentages.

## Semantics

TCP preserves stream semantics: exact/all helpers handle partial transfers,
peer EOF does not remove the write direction, and one accept is admitted at a
time. Cancellation/deadline of an accept is operation-local. Close and abort
wake pending accepts and retain their first cleanup owner.

UDP preserves one packet per operation, its source and explicit truncation.
Receive capacity is 1 through 65,507 bytes; capacity+1 scratch detects a packet
that exceeds retained capacity. A received zero-length packet is valid data,
not EOF. Results own their retained payload independently of scratch reuse.

The current std.net backend rejects zero-length sends with structured
`Unsupported` before native I/O and advertises `zeroLengthDatagramSend=false`.
The user approved this backend-only limitation; it does not narrow the
shared datagram model or remove mandatory empty receive. Nonempty sends are
atomic. An uncertain native send failure is never automatically retried.

One send and one receive may overlap. Connect excludes both directions.
Cancellation after UDP operation admission closes the owned native socket;
pre-cancelled admission leaves it reusable. A receive deadline alone leaves it
reusable. Terminal close is idempotent before consulting caller context.

### Control-flow paths

| ID | Conditions and boundary | Expected state or result | Reachability evidence |
|---|---|---|---|
| P001 | TCP bind: stopped context, backlog 0/-1/65,536, valid port zero, occupied address | structured rejection without returned resource, or actual bound endpoint | public listener regressions |
| P002 | TCP accept: admitted, overlapping, cancelled, expired or closed | one owner; ConcurrentOperation for overlap; operation-local stopped accept; close wakeup | public listener regressions |
| P003 | TCP stream: fragmented input/output, exact read, EOF then write | unchanged byte sequence; graceful EOF; write remains usable | independent Python TCP peers |
| P004 | UDP send: empty, 1..65,507 bytes, oversized, unconnected or Unix destination | Unsupported/MessageTooLarge/NotConnected as applicable; accepted packet is complete | public tests and native consumer |
| P005 | UDP receive: empty, below/equal/above capacity, later scratch reuse | source retained; exact truncation flag; no tail replay or retained-payload mutation | public tests and Python-produced packets |
| P006 | UDP connect while idle or receive active | native peer filter when admitted; ConcurrentOperation without replacing active receive | public tests and native wait handshake |
| P007 | UDP receive: pre-cancelled, expired, timed out, active cancellation or graceful close | untouched admission/reusable timeout versus Aborted/Closed terminal ownership | public tests and traced native waits |
| P008 | UDP receive active with another receive or opposite-direction send | reject second receive; permit complete send | traced native wait handshake |
| P009 | Repeated close/abort and stopped close admission | first cleanup owner retained; stopped admission has no native effect | public lifecycle regressions |
| P010 | Native descriptor creation, accept and repeated resource disposal | NONBLOCK+CLOEXEC at creation; no live socket descriptors at either resource checkpoint | strace and consumer /proc FD observations |
| P011 | A second close joins an owner using a background context | wait for actual completion or caller deadline; retain the owner's eventual result | gated stream close reproduction |
| P012 | Admitted native datagram send fails after the deadline expires | TimedOut with Never retryability, preserving cause and endpoints | public-clock fault reproduction |

### Semantic scenarios

| ID | Paths | Input or schedule | Required consumer-visible assertion |
|---|---|---|---|
| S001 | P001 | Invalid backlog, stopped bind and address conflict | stable error code/phase, available endpoint and native cause |
| S002 | P002 | Two accepts race without assuming which is scheduled first | exactly one ConcurrentOperation and one cancellation; no pending queue |
| S003 | P002,P009 | Cancel/expire accept, reuse listener, close or abort pending accept | usable listener after local cancellation; stable terminal owner after disposal |
| S004 | P003 | Independent TCP peers exchange 32 KiB in 1,021-byte fragments | exact byte equality, graceful EOF and successful post-EOF write |
| S005 | P004 | Empty and oversized send, missing peer, Unix endpoint | structured rejection and subsequent valid packet delivery on the same socket |
| S006 | P005 | Python sends a real zero-byte UDP packet | empty owned payload, non-truncated result and actual sender |
| S007 | P005 | Eight-byte packet into capacity four, then exact four-byte packet | first prefix/truncated; second exact/not truncated; first result unchanged |
| S008 | P004,P005 | Maximum 65,507-byte packet in both directions | complete single packet, byte equality and no false truncation |
| S009 | P006 | Native connect followed by wrong-peer and selected-peer packets | only selected peer is delivered, with correct source |
| S010 | P007,P009 | Pre-cancelled/expired receive or close, then ordinary I/O | socket remains Open and transfers a real packet |
| S011 | P007 | Empty receive wait reaches its deadline | TimedOut without terminal closure; later receive remains usable |
| S012 | P006,P007,P008 | Observe recvfrom EAGAIN, reject competing receive/connect, send opposite direction, then cancel | competing calls fail; Python receives live packet; pending receive returns Cancelled; Aborted retained |
| S013 | P007,P009 | Observe recvfrom EAGAIN before graceful close | pending receive returns Closed; Closed retained, not Aborted |
| S014 | P010 | IPv4 and IPv6 create/accept plus 64 create/close cycles each | creation flags in successful syscalls; zero socket FDs before and after cycles/wait cases |
| S016 | P009,P011 | Background close blocks while a bounded caller joins it | joining caller times out instead of reporting completion; eventual owner closes successfully |
| S017 | P004,P012 | Reentrant clock observes admitted send, closes the socket, then advances its deadline | native failure remains TimedOut and Never-retry; baseline reports Temporary |
| S015 | P001,P004,P009 | API inventory, public docs and whole-repository regressions | no leaked native API or stale public inventory; existing consumers still pass |

## Test-plan matrix

| ID | Scenarios | Command or evidence | Acceptance |
|---|---|---|---|
| T001 | S001,S002,S003,S005,S007,S009,S010,S011 | `cjpm test src/net --no-progress --no-color` | all selected public cases pass; no native-empty-send success claim |
| T002 | S003,S004,S010,S011 | `cjpm test src/internal/transport_stdnet --no-progress --no-color` | TCP backend regressions retain prior behavior; existing exclusions remain visible |
| T003 | S004,S005,S006,S007,S008,S009,S012,S013,S014 | `python3 tools/m8_002_native_sockets.py` | both address-family profiles pass against independent Python peers; actual native wait observed before cancellation/close |
| T004 | S005,S006 | `sdk-primitive-qualification.json` and `sdk-primitives/` | raw SDK limitation remains explicit; external zero-byte receive is preserved |
| T005 | S015 | manifest public-api-inventory and public-api-documentation commands | new baseline matches actual declarations and public documentation builds |
| T006 | S001,S015 | manifest fast gates, repository-full-check and repository-regression-tests | exact command results recorded without promoting skips or compile-only checks to runtime proof |
| T007 | S016,S017 | `review-corrections.json`, public regression and archived admitted-send reproduction | baseline failures become passing public behavior; no call-count assertion |

The native runner uses a separate cjpm consumer that imports only public
Wirestack APIs. Its Python peers are not Wirestack wrappers. Cancellation and
close are triggered only after strace records the pending socket's real
nonblocking receive attempt; process handshakes delimit reused descriptor
numbers. The FD checks count socket descriptors owned by that consumer, not
unrelated runtime file descriptors.

No line/branch coverage, mutation score, privileged raw-socket run or release
soak result is inferred from this matrix. Final executed results and candidate
provenance belong to the corresponding JSON reports and evidence seal.
