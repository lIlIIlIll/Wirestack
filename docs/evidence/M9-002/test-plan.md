# M9-002 typed socket option test plan

Scope: Native socket-option support is qualified only on Linux x86_64 glibc for TCP listener, outgoing and accepted TCP, and Internet UDP options. Unqualified-target fallback is simulated through an internal qualification seam; this does not qualify another platform. No Unix option API, arbitrary native option pass-through or UDP membership API is added.

## Control-flow paths

| Path ID | Condition | Expected terminal |
|---|---|---|
| P001 | Creation list has invalid domain, duplicate, excessive count or wrong target/family | Reject before socket allocation |
| P002 | Caller overrides or omits a default | Qualified target applies remaining defaults then caller order; unqualified target skips provider defaults |
| P003 | Valid pre-bind option followed by bind | Kernel behavior and readback retain configured option |
| P004 | Connected TCP or bound UDP configure | Exclusive control admission; ordered partial application |
| P005 | Effective value queried | Native value, including buffer adjustment; no request echo |
| P006 | Unsupported family/query or immutable post-bind option | Stable Unsupported or InvalidState; healthy socket remains usable |
| P007 | Configuration fails at first, middle or last executor step | Earlier runtime effects retained; factory resources closed |
| P008 | Accepted option failure | Close only accepted socket; next accept succeeds |
| P009 | Read/write/send/receive/connect/accept overlaps control | Bidirectional fail-fast exclusion; existing operation continues |
| P010 | Cancellation, expiry, close or abort races control | Original context and first terminal owner preserved; no healthy-socket cancellation abort |
| P011 | Installed consumer uses options via public API and HttpConnector | No checkout or internal API dependency; real traffic and cleanup |
| P012 | API, capability, documentation or source evidence changes | Current task reports agree; historical reports remain unchanged |
| P013 | Empty or explicit caller list on an unqualified platform | Accept empty lists and preserve basic networking; reject explicit options as Unsupported before allocation; omit Linux defaults |
| P014 | IPv4 UDP on provider-qualified versus unqualified target | `socket.capabilities.broadcast` is true only when native option qualification is true; empty-option bind still works on an unqualified target |
| P015 | IPv6 UDP on provider-qualified versus unqualified target | `socket.capabilities.broadcast` is false in both cases; Broadcast apply/query remains Unsupported |

## Semantics and scenario matrix

| Scenario ID | Input and pre-state | Path IDs | Expected behavior | Required assertions | Type |
|---|---|---|---|---|---|
| S001 | Buffers -1/0/1/Int32.Max/+1, interface 0/max/+1, duplicate names, 13 entries | P001 | Whole-list validation precedes allocation or mutation | Invalid arguments do not change preceding valid option or consume a port | boundary |
| S002 | Empty/default/overridden listener and outgoing/accepted TCP lists on qualified Linux | P002,P003 | ReuseAddress true; NoDelay true and KeepAlive false unless overridden | Native readback and retained option independence | native |
| S003 | IPv4/IPv6 UDP, listener and TCP option matrix | P003,P004,P005,P006 | Set/query each supported option; reject wrong target/family/stage | Real values, IPv4 interface readback Unsupported, buffers not echoed | native,boundary |
| S004 | Two same-address listeners and IPv6-only listener | P003 | ReusePort and IPv6-only alter real bind/connect behavior | Independent connections or expected bind/connect rejection | native |
| S005 | Executor fails at first/middle/last item | P007,P008 | No later execution; partial runtime state remains; new ownership reclaimed | Kernel readback, descriptor closure and subsequent listener success | fault |
| S006 | Blocked read/write/receive/accept versus control; blocked control versus I/O | P009 | ConcurrentOperation in both directions | Barrier-controlled admission; original operation completes after peer progress | concurrency |
| S007 | Pre-cancelled/expired context, cancellation between options, close/abort race | P010 | No pre-admission side effect; remaining options stop; terminal cause retained | Effective values, continued healthy I/O and terminal classifications | concurrency,boundary |
| S008 | Installed public-only application with TCP, UDP and custom HttpConnector | P011 | Actual configure/connect/query/traffic/close from extracted package | Source/archive/SDK binding and resource recovery | installed |
| S009 | New enum cases, named parameters, docs and capability map | P012 | Source/exhaustive-match/ABI effects documented separately | Inventory and architecture/documentation checks; no untested ABI claim | compatibility |
| S010 | Simulated unqualified target with empty and explicit TCP lists | P001,P002,P013 | Empty list passes for listener/TCP/UDP; explicit option returns Option/Unsupported; provider defaults are skipped | Validation classification and zero default-executor calls when unqualified; qualified TCP/listener still apply two/one defaults | regression |
| S011 | Internet UDP IPv4 and IPv6 with provider option qualification on and off | P014,P015 | Broadcast capability true only for qualified IPv4; unqualified IPv4 and all IPv6 false; multicast membership remains unsupported | All four address/qualification combinations and bound facade reflect capability contract | regression |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001,S002,S003,S004 | P001,P002,P003,P004,P005,P006 | Public net socket option tests | PASS | Typed error domains, kernel values, pre-bind behavior and unchanged valid sockets | regression,native |
| T002 | S005,S006,S007 | P007,P008,P009,P010 | Adapter fault and barrier-controlled tests | PASS | First/middle/last failure cleanup, ordering, cancellation and exclusion | fault,concurrency |
| T003 | S008 | P011 | Installed socket option consumer | PASS | TCP/UDP and HttpConnector behavior with public APIs and bounded cleanup | installed |
| T004 | S009 | P012 | API inventory, architecture guard, HTML docs and canonical checks | PASS | No native type leakage; docs/capability facts match implementation | integration |
| T005 | S010 | P001,P002,P013 | Qualification-injected validator and default-application tests | PASS | Empty lists remain accepted for all factory targets; explicit options preserve stable Unsupported; unqualified TCP/listener defaults produce no calls while qualified TCP/listener retain two/one defaults | regression |
| T006 | S011 | P014,P015 | `udpBroadcastCapabilityRequiresQualifiedIpv4Support` | PASS | Qualified IPv4 true; unqualified IPv4 and both IPv6 qualification cases false; live facade matches provider qualification | regression |

## Evidence boundaries

The SDK probes are prerequisite checks, not Wirestack acceptance. Compilation alone is not a native PASS. Unqualified-target behavior is exercised on Linux through internal qualification injection; this does not qualify another platform. This task has no new parser or fuzz claim. Existing deadline, EOF, full-duplex and close/abort regressions remain required. Completion requires evidence sealed against the exact source candidate.

## Executed mapping

- T001: `M9002SocketOptionTest`, 11 cases. Includes buffer -1/0/1/Int32.Max/+1, interface 0/max/+1, Bool toggles, TTL/hop endpoints, complete-list rejection, type/family/stage errors, real ReusePort and IPv6-only/dual-stack behavior. Bool and UInt8 invalid domains are excluded by the public types rather than fabricated runtime inputs.
- T002: `M9002OptionExecutionTest`, 15 cases. All factory and accepted first/middle/last executor failures reclaim the owned socket; runtime failures preserve exactly the successful prefix. Caller mutation cannot change accepted policy. Barrier-controlled tests cover TCP read/write, UDP receive, listener accept, query/configuration in both directions, cancellation between options, and first close/abort ownership. Listener-close-before-publication is a retained red/green regression.
- T003: installed `socket-options`, `http-option-connector`, `invalid-option-admission` and `active-send-control`, plus the seven requalified baseline native scenarios. Invalid factory inputs cause no native socket allocation; delayed real `sendto` holds admission while query/configure reject and the packet still arrives intact.
- T004: 24 focused capability receipt mutation checks; API inventory, architecture guard, full canonical repository gate and generated HTML. The old exhaustive-match client executes on the M9-001 archive and fails compilation on precisely the four added variants in the current archive. Old-binary and cross-SDK execution are NOT_RUN.
- T005: two internal qualification-injected regressions accept empty option lists for TCP, listener and UDP targets, preserve Option/Unsupported for explicit options, skip TCP/listener defaults on an unqualified target, and retain two TCP plus one listener default on a qualified target. No non-Linux native result is claimed.
- T006: Focused Cangjie regression `udpBroadcastCapabilityRequiresQualifiedIpv4Support` verifies all four address-family/qualification combinations and the live bound `UdpSocket` capability on this Linux-qualified build; no non-Linux native claim.

Exact command results and normalized logs are linked from `task-check.json` and `verification.json`; no filtered or unavailable case is counted as passed.
