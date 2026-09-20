# M8-003 Linux Unix socket qualification

M8-003 adds public `UnixStream`, `UnixListener`, and capability-scoped `UnixDatagramSocket` on Linux x86_64 glibc. The backend uses public `std.net` APIs and does not expose SDK sockets or native handles. Raw native I/O remains **BLOCKED**.

The qualified compiler is Cangjie 1.1.3. The daily 1.1.0-alpha.20260829040003 SDK was used for the outgoing non-UTF-8 abstract-name probe, not for the complete native matrix. This task makes no non-Linux or final-release claim.

## Supported behavior and exclusions

| Surface | Qualified result |
|---|---|
| Pathname stream connect/accept | PASS; exact bidirectional bytes, stable EOF, write after EOF, cached endpoints |
| Abstract stream/datagram addresses | PASS only for outgoing names of exactly 107 valid UTF-8 bytes; embedded NUL is retained |
| Short outgoing abstract names | BLOCKED: SDK sockaddr length 110 adds significant trailing NUL bytes; adapter rejects rather than renames |
| Non-UTF-8 outgoing abstract names | BLOCKED: SDK address conversion rejects invalid Unicode; shared endpoint byte model remains unchanged |
| Named datagram sender metadata | PASS, including an independent short abstract sender containing 0xFF |
| Unbound datagram sender | BLOCKED: SDK consumes the packet then fails address conversion; no fabricated source or recovered packet |
| Explicit Unix `sendTo` and owned receive | PASS; empty receive, exact/truncated packets, stable owned bytes and 65,507-byte payload |
| Unix connected `send` | BLOCKED: even concrete SDK send re-resolves the peer address; `connectedDatagramSend=false` and the adapter fails closed |
| Unix connected receive filtering | PASS, including after the selected pathname is replaced |
| Empty datagram send | Unsupported before native I/O; subsequent explicit positive send succeeds |
| Pathname cleanup | Caller-owned; close releases the descriptor but does not unlink the filesystem node |
| Raw domains, ancillary and sequence packets | No raw adapter; IPv4/IPv6/Packet/Netlink open requests return Unsupported. AF_PACKET, AF_NETLINK, SOCK_SEQPACKET and ancillary I/O are not success claims |

See [the scenario matrix](test-plan.md), [SDK qualification](sdk-primitive-qualification.json), and [the native report](native-sockets.json). A successful rejection guard is not a successful native implementation of the rejected capability.

## Native proof

The [clean external consumer](../../../examples/linux/m8_003/main.cj) runs against independent Python AF_UNIX peers through [the runner](../../../tools/m8_003_native_sockets.py). It does not use same-SDK loopback to infer address identity.

Both pathname and supported abstract profiles pass:

- 32,768-byte stream exchanges, stable EOF and post-EOF write.
- Accept/read/receive cancellation or close only after strace observes native EAGAIN; opposite-direction operations remain usable where the contract permits.
- A 1 MiB write to a non-reading peer reaches sendto EAGAIN and a real two-second deadline. Its error is Write/TimedOut, Retryability.Never, with native cause and Unix endpoint.
- 64 stream/listener and datagram creation/disposal cycles. Socket FD sets are empty at live baseline and final checkpoints.
- Atomic NONBLOCK/CLOEXEC creation flags on all observed socket and accept operations. Pathname: 70 stream creations, 5 accepts, 68 datagram creations. Abstract: 70 stream creations, 5 accepts, 67 datagram creations.
- Connected-send rejection cannot deliver a packet to either the original or replacement pathname peer. Native receive filtering still selects the original peer; explicit sendTo reaches the address the caller supplies.

## Review corrections

[Independent review evidence](review.json) records two distinct results:

1. Lifecycle admission does not promise that an SDK exception already exists. A bounded 512-iteration reproduction produced 453 valid cancellations without a native cause. Removing the incidental cause-presence assertion made the same 512-iteration reproduction pass while retaining error classification, endpoint and first-close ownership assertions. Temporary instrumentation is not retained in the test suite.
2. Replacing a connected pathname while keeping the original peer alive caused a payload to reach the replacement socket. Switching from sendTo to the concrete SDK send did not fix it. The final capability guard reports Unsupported before native send; explicit addressing and receive filtering remain available.

An obsolete helper-only write-timeout test and its unused error helpers were removed. Public native backpressure now supplies the write-timeout proof.

## Local command record

| Gate | Result | Record |
|---|---|---|
| Cangjie check/build | PASS | `cangjie-check.json`, `cangjie-build.json` |
| Existing public network contracts | PASS, 48/48 | `network-tests.json` |
| Canonical transport regressions | PASS, 33 passed; 17 existing Performance exclusions | `transport-tests.json` |
| Independent native Unix consumer | PASS with the explicit capability exclusions above | `native-consumer-command.json`, `native-sockets.json` |
| API inventory | PASS, 265 declarations and 103 resolved aliases | `api-inventory-command.json`, `api-inventory.json` |
| Plan, architecture and task contracts | PASS | `plan-validation.json`, `architecture-guard.json`, `task-validation.json` |
| API documentation | PASS, 1,163/1,163 symbols and 492/492 parameters documented | `docs-command.json`, `docs-report.json` |
| Full repository check | PASS, 638 Cangjie cases; 23 existing exclusions | `full-check.json` |
| Selected Python regressions | PASS, 116/116 | `regression-tests.json` |

All 12 manifest acceptance commands pass. No line coverage, mutation, fuzzing, one-hour SSE, or 86,400-second soak result is claimed here.

## Compatibility and publication

The current inventory contains 265 declarations and 103 resolved aliases. It adds the three Unix classes and `SocketCapabilities.connectedDatagramSend`. The extra struct field and constructor parameter are an intentional pre-1.0 **ABI break: rebuild consumers**. Existing call forms retain defaults. UdpSocket.close has an inventory whitespace-only change, not a parameter or return-type change. See [compatibility classification](api-compatibility.json).

Implementation and publication are confined to a standalone clone of merged M8-002 `df25890a1cc39ff3ad35d75f781ce1993fe2edc4`. The original workspace's 1,191 staged entries match the session baseline; this task has no original-worktree write targets. [The safety record](workspace-safety-publication.json) records the observed check, not a claim about earlier tasks.

The source candidate must be committed before evidence binding and sealing. The canonical `evidence.json` records that source revision and typed report/input digests; the subsequent evidence commit is identified by the publication branch and PR. Publication retains the exact source candidate under an immutable evidence tag before linear-history merge. Remote-only verification is a separate required step, not inferred from local tests.
