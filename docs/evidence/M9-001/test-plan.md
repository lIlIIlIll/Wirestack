# M9-001 public network capability test plan

Scope: the existing Linux x86_64 glibc public network operations, their capability
claims, and registration of the 16-task roadmap. No new socket option, multicast,
raw socket, timeout policy or release qualification is implemented.

## Control-flow paths

| Path ID | Condition | Expected terminal |
|---|---|---|
| P001 | Default and native UDP capability values advertise unavailable options | Regression fails before correction; false afterwards |
| P002 | Maintained description references existing operations, fields, backend symbols and conditions | Static mapping and both generated tables agree |
| P003 | A public operation, capability row, condition, backend or scenario disappears | Consistency check rejects drift |
| P004 | Fresh package is extracted outside checkout and used as the sole dependency | Native consumer is bound to installed source, artifact and SDK |
| P005 | IPv4/IPv6 TCP and UDP factories and I/O succeed | Actual flags, descriptor flags, packet/stream semantics and cleanup agree |
| P006 | Unix pathname and exact 107-byte UTF-8 abstract endpoints are used | Named byte identities preserved; pathname unlink remains caller-owned |
| P007 | Half-close, empty send, Unix connected send, invalid abstract or raw open is requested | Typed failure; no new socket/background resources; usable sockets stay usable |
| P008 | Named arbitrary-byte or unbound Unix datagram source is received | Named source preserved; unbound SDK conversion failure remains a real failure |
| P009 | Configured DNS client/resolver or bounded public DNS parser executes | Query/lookup/connect/parser behavior works from installed package |
| P010 | Native receipt has missing/skipped/failed/permission-denied/cross-compiled scenarios | No native PASS or permanent platform downgrade |
| P011 | Source, SDK, description, execution input, archive or retained log changes | Native receipt rejected as stale or tampered |
| P012 | All roadmap rows are registered | Unique IDs/issues, actual start dependencies and separate completion integrations |
| P013 | Public constructor defaults change without changing field/method/enum shape | Explicit semantic migration; no untested old-binary compatibility claim |

## Semantics and scenario matrix

| Scenario ID | Input and pre-state | Path IDs | Expected behavior | Required assertions | Type |
|---|---|---|---|---|---|
| S001 | Default SocketCapabilities and bound UDP socket | P001 | Broadcast/multicast false; connected Internet send retained | Four erroneous true values fail before fix | regression |
| S002 | Current 9 fields on all 6 socket classes and callable net families | P002 | Complete mapping with callable symbols and stable unavailable-operation reasons | No type-only Supported claim or unmapped public operation | static |
| S003 | Remove operation/field/condition/backend/scenario or change generated table | P003 | Nonzero consistency result | No silent drift or second hand-maintained support table | negative |
| S004 | Fresh archive, qualified SDK and out-of-checkout install | P004 | Consumer builds/runs only against install | Source and typed artifact/SDK/input digests match | native,identity |
| S005 | IPv4 and IPv6 loopback TCP/UDP peers | P005 | Factory/I/O/EOF/packet boundaries and native descriptor flags agree | Separate internet-ipv4 and internet-ipv6 PASS | native |
| S006 | Unix pathname and valid full-length abstract peers | P006 | Real I/O, accepted/outgoing flags and caller cleanup | Separate unix-pathname and unix-abstract PASS | native |
| S007 | Open healthy sockets followed by unsupported calls; all raw domains | P007 | Stable category/phase/code/retryability, original state and continued I/O | FD/task/checkpoint and syscall evidence; no raw syscall | native,negative |
| S008 | Short/non-UTF-8 incoming named source, then unbound sender | P008 | Preserve named bytes; report unbound-source conversion failure | No invented unnamed packet or restored consumed packet | native,boundary |
| S009 | Explicit controlled DNS peers plus complete/truncated packet | P009 | DNS client, resolver connect and parser execute public APIs | dns-basic, dns-connect and capability-contract assertions | native |
| S010 | Failed/skipped/missing scenario, absent native proof or wrong target | P010 | Reject native qualification | Permission failure is environment failure, not Supported or permanent false | negative |
| S011 | Mutate each bound identity or bytes after receipt | P011 | Reject stale receipt | Source/SDK/conditions/helper/artifact/nested logs checked, not status alone | negative,identity |
| S012 | Sixteen roadmap rows, P1 mappings and existing CookieJar | P012 | 224 release-related and 246 total unique tasks | Dependencies not confused with later completion integrations | planning |
| S013 | Baseline and current declaration inventory; rebuilt consumer | P013 | Only intended constructor defaults/UDP semantics change | Source, exhaustive-match, semantic, inventory and ABI dimensions separate | compatibility |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001 | P001 | M8002UdpSocketTest.unavailableOptionOperationsAreNotAdvertised | Pre-fix FAIL; post-fix PASS | Four option claims corrected; connected UDP send not removed | regression |
| T002 | S002,S003 | P002,P003 | tools.tests.test_network_capabilities | PASS | Removed operations/conditions/fields/backend/scenarios and doc drift rejected | negative |
| T003 | S004,S005,S006,S007,S008,S009 | P004,P005,P006,P007,P008,P009 | tools/m9_001_native_capabilities.py --offline | All seven native scenarios PASS | Installed public-only consumer, independent peers, resource and typed failure assertions | native |
| T004 | S010,S011 | P010,P011 | Native receipt mutation regressions and real CLI verification | Mutations rejected; clean receipt PASS | No missing execution, stale input, artifact or log is accepted | negative,identity |
| T005 | S012 | P012 | tools.tests.test_m7_linux_task_graph | PASS | Unique 16-task DAG, issue mapping and calculated counts | planning |
| T006 | S013 | P013 | Current API inventory and installed rebuilt consumer | Explicit classification | No field/method/case additions or removals; old binary execution NOT_RUN | compatibility |
| T007 | S001,S002,S004,S005,S006,S007,S009,S012,S013 | P001,P002,P004,P005,P006,P007,P009,P012,P013 | scripts/check-task M9-001, scripts/check-docs --html and scripts/check | PASS if all actual commands succeed | Architecture, docs, existing protocol/resource regressions remain valid | integration |

## Evidence boundaries

P1-015 was verified before implementation. Its production digest is intentionally
historical after this task changes the capability defaults; it is not rewritten.
No historical M8 report is qualified or replaced. New evidence remains a working-tree
receipt until a separately authorized source commit and evidence seal exist.
No line/branch coverage, fuzz improvement, formal independent security review,
86,400-second soak, release signature, non-Linux support or system-DNS deployment
matrix is claimed by this task.
