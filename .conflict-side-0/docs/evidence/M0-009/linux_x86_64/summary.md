# GATE-NET-04 — Linux x86_64 supplied-SDK result

**Task:** COMPLETE  
**Linux FIN/RST/local-close classification:** PASS  
**Linux gate:** INCOMPLETE  
**Global gate:** INCOMPLETE

## Runtime results

| Scenario | Samples | Terminal result | Decision |
|---|---:|---|---|
| peer graceful FIN | 20 | `read()` returned `0` in 20/20 | PASS |
| peer RST | 20 | `SocketException` in 20/20 | PASS |
| local close during blocked read | 20 | `SocketException` in 20/20 | PASS |
| deterministic close/read races | 90 | causally ordered EOF/local-close outcomes | PASS |

The supplied Linux SDK distinguishes peer EOF from peer RST and local active
close without matching exception message text.

## Race distribution

| Ordering | Samples | Observed terminal |
|---|---:|---|
| peer FIN scheduled first | 30 | EOF before local close, 30/30 |
| local close scheduled first | 30 | `SocketException` after local close, 30/30 |
| equal configured delay | 30 | EOF before local close, 30/30 |

The equal-delay samples record the peer event winning this host's scheduling
race. No local-first sample was collapsed into peer EOF.

## Public capability probes

| Capability | Result | Diagnostic SHA-256 |
|---|---|---|
| `TcpSocket.abort()` | BLOCKED — member unavailable | `96c3bec4d2156ce50b1841bcbcde62d0410d0480d99e30982ff108081845c67d` |
| `TcpSocket.cancel()` | BLOCKED — member unavailable | `47011594ea41703dfccf689ada9cac85e448376e5d21bc62290802a7fe43ce0a` |

Because abort and cancellation are not public capabilities, the complete Linux
GATE-NET-04 remains **INCOMPLETE** even though the available terminal evidence
is stable.
