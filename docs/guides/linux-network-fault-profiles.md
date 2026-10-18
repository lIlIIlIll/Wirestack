# Run isolated Linux network fault profiles

The M12-003 network runner builds an installed public Wirestack consumer from the verified development archive, then creates an owned unprivileged user and network namespace. DNS, TCP peers, packet filters and qdiscs exist only in that namespace. It never changes host routes, firewall rules or kernel modules.

## Prerequisites

- Explicitly selected STS SDK. The current evidence uses `$HOME/cangjie_sdk/sts1.1.3` through `$HOME/.codex/scripts/codex_cangjie_env`.
- Linux x86_64 with glibc, Python 3, a native C compiler, `unshare`, `ip`, `tc` and `setpriv`.
- A disk-backed private scratch directory with room for the installed archive and consumer build.
- Kernel support for `sch_netem`, `sch_ingress`, `cls_flower` and `act_gact` available to the isolated namespace. Userspace `tc` alone is insufficient.

The current host returns `tc` exit 2 with `Specified qdisc kind is unknown`. `modinfo` also reports missing `sch_netem` and `sch_ingress`. Preserve this as a blocked packet-fault prerequisite. Do not substitute application sleeps or retry the same environment to manufacture a pass. Use an authorized owned guest with the required kernel support, the exact STS bytes and a compatible glibc runtime.

## Run the complete profile set

Use a new scratch directory. The runner verifies archive membership and binds the consumer, production inputs, the namespace/impairment/sampling helper (`tools/gates/m2_015_native_network.py`), the compiled test-only resolver interposer source (`tools/gates/native/gai_delay.c`), selected provider archives and the complete STS compiler/runtime/import closure in the report.

```sh
scratch=$(mktemp -d "$HOME/.cache/agent-tmp/m12-003-network.XXXXXXXX")
chmod 700 "$scratch"
python3 tools/gates/m12_003_network.py \
  --sdk-root "$HOME/cangjie_sdk/sts1.1.3" \
  --archive docs/evidence/M12-001/native-final/wirestack-baseline.tar.gz \
  --scratch "$scratch" \
  --output docs/evidence/M12-003/network/replay \
  --seed 12003
```

The runner writes `report.json` and `profiles.json`. Exit 0 means every selected profile passed its semantic and fault-application checks. Exit 1 retains FAIL or BLOCKED evidence. A selected subset is not complete network coverage.

| Stable profile ID | Applied fault and required proof |
|---|---|
| `dns_no_response` | A real UDP nameserver receives a query and withholds the first response. The native consumer reaches its absolute deadline, then validates a fresh response. |
| `dns_late_result` | The native deadline event releases a late answer to the old UDP query. A different query must receive its own answer without accepting the late result. |
| `ipv6_blackhole` | An IPv6 SYN-drop filter must count real dropped traffic while the public HTTP connector succeeds through reachable IPv4. |
| `multicandidate_cancel` | Both address-family candidates are subject to drop filters. The public connector's second candidate triggers cancellation; joined cleanup must complete. |
| `delay_loss` | A real 20 ms netem delay precedes an event-controlled 100% loss interval. After the first request arrives, the peer installs loss, submits the original response, proves a dropped packet, and removes loss. Kernel TCP retransmission must deliver the exact seeded payload, with no application retry. |
| `rst` | A native peer receives bytes, applies zero-second `SO_LINGER`, then closes. RST must remain distinct from EOF and deadline. |
| `silent_disconnect` | The peer installs an actual packet-drop action after receiving the request. Deadline, counters, removal and new-connection recovery must be observed. |
| `peer_no_read` | A native accepted socket stops reading with a measured small receive buffer. Bounded writes make progress before hitting the shared deadline. |
| `peer_no_write` | A native peer reads the request but never writes a response. Native read deadline and cleanup are required. |
| `http_rst`, `http_no_write` | A failed public HTTP request must leave no active pooled connection. A fresh request on the same client must use a second physical connection and validate its response. |
| `system_resolver_boundary` | A TEST ONLY `getaddrinfo` interposer holds a synchronous system operation for 800 ms. One worker and one queue slot remain bounded; abandoned work is still measured after the caller's deadline and later drains to zero. |

Every successfully exercised fault profile also runs a new native TCP echo after impairment removal. HTTP recovery additionally proves the failed connection was excluded from the same client's pool. Packet counters and fixture events are separate evidence; fixture delay is never labeled netem.

## Replay retained binaries

`--profile` may be repeated to select stable IDs. Add `--reuse-build` with the original scratch to replay the retained installed binary without recompilation. The runner rejects changed source, archive, STS or binary bindings. Transfer the whole scratch tree into an authorized guest, not just the executable. Relative installed dependencies remain `../../install/wirestack`.

A changed runner or consumer requires a fresh build and a new scratch. Replay logs must name their own environment and seed. Historical failed evidence remains unchanged.

## Interpret cleanup and limits

The report records live baseline and reclaimed `/proc` snapshots after a real public TCP warmup initializes SDK AIO, periodic FD/socket/thread/RSS samples, public HTTP owner/request/connection/stream/buffer counters, and real resolver work counters. Input acknowledgements hold the native process at both sample points. RSS is allocator retention, not a count of live objects. Socket and resolver public APIs do not expose a registration count; that field is explicitly UNAVAILABLE, never fabricated zero.

Peers, sampler threads and owned native process groups have bounded shutdown. `setpriv --pdeathsig KILL` prevents an orphaned native consumer from surviving its runner. Native owners close in `finally`, including failed requests and abandoned resolver work. Reports retain exact commands and normalized logs.

The existing public socket normalizer maps SDK exceptions it cannot categorize to `SystemFailure` (`src/net/package.cj`). RST profiles record that code distinctly rather than relabeling it `ConnectionReset`; actual abortive-close events, failure rather than EOF/deadline, and unhealthy-pool exclusion remain mandatory.

In an authorized netem-capable guest, also run `WIRESTACK_NETWORK_PACKET_TESTS=1 python3 -m unittest tools.gates.tests.test_m12_003_network` to exercise original-response packet loss and kernel retransmission. This test is explicitly skipped on the known missing-module host.

Run the fixture regression tests separately:

```sh
python3 -m unittest tools.gates.tests.test_m12_003_network
```

M12-003 smoke and scheduled stress are development evidence only. These runs remain `NOT_QUALIFIED`. They do not execute or replace the separate 86,400-second formal candidate gate, and they authorize no commit, publication or signing.
