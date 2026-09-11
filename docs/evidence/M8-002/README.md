# M8-002: Linux TCP and UDP

M8-002 adds `wirestack.net.TcpListener` and `UdpSocket` over the public
`std.net` APIs. `TcpStream` reuses the qualified transport backend. Factories
accept resolved Internet endpoints and do not perform DNS lookup.

## Implemented behavior

- TCP listeners admit one accept. Cancellation or deadline stops that accept
  without destroying the listener. Close and abort wake pending accepts.
- TCP exact/all operations preserve stream bytes across partial transfers.
  Peer EOF does not remove the write direction.
- UDP sends preserve packet atomicity. Receive returns an owned payload,
  source endpoint and truncation flag. A later receive cannot mutate an older
  result, and a truncated packet's tail is not replayed.
- UDP permits one send and one receive together. A second same-direction
  operation, or connect during I/O, returns `ConcurrentOperation`.
- Pre-cancelled UDP admission leaves the socket open. Active cancellation
  closes its owned native socket and retains `Aborted`. A receive deadline
  alone leaves the socket reusable. Graceful close retains `Closed`.
- All three public socket classes make a joining close wait for an admitted
  background close. Completion coordination is allocated only when needed.
- A valid nonempty UDP send without a selected peer returns `NotConnected`.
  An admitted send failure with uncertain physical commit is non-retryable,
  including when its native exception crosses an expired deadline.

## Empty packets and bounds

The shared datagram model includes empty packets. The independent Python peer
sends a real zero-byte UDP packet, and the public consumer must receive it as
empty data with its sender and `truncated=false`.

The current std.net backend cannot send empty packets. Pinned compiler 1.1.3
and daily compiler 1.1.0-alpha.20260829040003 both report `SocketException`
without closing the sending SDK socket. The user approved limiting this
backend's empty-send capability, not the datagram model. `UdpSocket` therefore
advertises `zeroLengthDatagramSend=false`, returns structured `Unsupported`
before native I/O, and remains usable for nonempty sends.

Public UDP payloads and receive capacities are bounded to 65,507 bytes.
Receive capacity must be positive. The backend uses capacity+1 scratch to
detect truncation. The native consumer checks the maximum packet in both
directions for IPv4 and IPv6.

## Native qualification

Run from the repository root with the qualified Cangjie SDK, Python 3 and
`strace` available:

```bash
python3 tools/m8_002_native_sockets.py
```

The runner builds `examples/linux/m8_002/main.cj` as a separate cjpm consumer
using only public Wirestack APIs. Independent Python peers verify TCP bytes,
EOF, UDP packet boundaries, zero receive, selected-peer filtering and the
maximum packet. Successful socket/accept syscalls must include
`SOCK_NONBLOCK` and `SOCK_CLOEXEC`.

Cancellation and graceful close are triggered only after strace observes the
pending UDP socket's `recvfrom` returning `EAGAIN`. During the pending receive,
the consumer also rejects a competing receive/connect and sends a packet in
the opposite direction. Each address family performs 64 create/close cycles.
The consumer must own zero socket descriptors at both resource checkpoints.

`native-sockets.json` records the executed profiles, typed log digests and FD
observations. `sdk-primitive-qualification.json` preserves the SDK limitation
separately. Daily-SDK primitive checks do not claim a daily-SDK Wirestack
qualification matrix.

## Review and compatibility

`review-corrections.json` records two public regression failures before repair
and 48 passing cases afterward. The separate admitted-send reproduction exits
42 with retryable classification before the targeted correction and exits 0
with `Retryability.Never` afterward. Its source and raw output are preserved in
`review-reproduction/`; `corrections.patch` records the reversible source delta.

The initial review proof above belongs to source candidate
`408a0c92e1111ad7b8b533e92ded1d624cda558b`. A later PR review removed the UDP
adapter's redundant second SDK close after an exception. Both graceful close
and abort now invoke the SDK once, only after claiming native ownership;
the original exception is not replaced by another cleanup attempt.

`review-native-close.json` records an actual libc fault-injection experiment:
the selected UDP descriptor is closed successfully, then libc reports EIO.
The pinned SDK returns success and performs one native close both before and
after this correction. This does not reproduce a double kernel close or prove
the SDK-exception failure path. The correction removes the redundant source
path; the experiment and native lifecycle suite provide bounded smoke proof.

The API inventory adds `TcpListener` and `UdpSocket`. `SocketCapabilities`
gains `zeroLengthDatagramSend` and its named constructor parameter. This is an
intentional pre-1.0 ABI change. Rebuild consumers. A matching new inventory is
not proof of compatibility with old binaries; see `api-compatibility.json`.

## Final acceptance

- All three task-specific fast commands and nine task commands pass.
- Public network tests: 48 passed. Transport regression: 34 passed and 17
  existing `Performance` cases excluded, matching `scripts/check-code`.
- Canonical `scripts/check`: 639 Cangjie tests passed, 23 existing exclusions,
  no errors or failures. Its Python suites pass 413, 178 and 24 cases.
  The focused repository regression command passes 116 cases.
- Public inventory: 262 declarations and 103 aliases. Generated API
  documentation covers all 1,118 symbols and 450 parameters.
- IPv4 and IPv6 native profiles pass. Each observes 66 TCP creations, one TCP
  accept and 67 UDP creations, with no live socket FDs at either checkpoint.
  These are bounded native lifecycle checks, not long-duration leak or
  performance claims.

`qualification-setup.json` separates toolchain and invocation corrections from
behavioral regressions. The initial documentation environment selected cjdoc
0.7.1; `CJDOC_BIN` now selects the qualified 0.7.2 executable. The standalone
transport command initially selected external-profile benchmark fixtures;
only that command was retried under the canonical Performance exclusion.
No production source changed between the final task run and that retry.

## Publication evidence

`tools/tasks/M8-002.json` defines the exact acceptance commands and source
inputs. Command reports, `evidence.json` and `index.json` provide the final
execution and committed-candidate provenance. Only the full gate and a valid
seal permit publication as complete.

`workspace-safety-publication.json` records the isolated clone and the original
repository's unchanged NUL-delimited staged-entry snapshot. Publication does
not use the dirty original workspace. Under the repository's linear-history
rule, the exact source candidate must remain available through its
content-addressed `evidence/M8-002/<candidate>` tag before merge.

Unix/raw adapters, DNS wire transport, HTTP/TLS replacement, coverage claims
and release soak are not established by this task. M8-003 through M8-007 retain
their own acceptance gates.
