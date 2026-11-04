# M9-001 public network capability test plan

Scope: requalify the seven foundational Linux network scenarios and the current
capability map through the existing eighteen-scenario M9-003 runner. The auxiliary
receipt keeps its M9-003 identity. No new network operation or release qualification
is implemented, and the strict current-map validator remains unchanged.

## Control-flow paths

| Path ID | Condition | Expected terminal |
|---|---|---|
| P001 | Constructor defaults and factory-specific capability values are observed independently | Each matches the current maintained capability contract |
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
| P013 | Baseline and current declaration inventories differ | Record actual additions/removals/changes and separate semantic, source and untested binary dimensions |
| P014 | Current-map correspondence requires the M9-003 eighteen-scenario receipt | Execute the unchanged auxiliary runner as a separate long gate; never relabel the seven-scenario receipt |

## Semantics and scenario matrix

| Scenario ID | Input and pre-state | Path IDs | Expected behavior | Required assertions | Type |
|---|---|---|---|---|---|
| S001 | Default SocketCapabilities and factory-created socket objects | P001 | Defaults and instance-dependent flags match their current contracts | Observe all nine flags separately on each installed socket class | regression,native |
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
| S013 | Baseline and current declaration inventory; rebuilt consumer | P013 | Classify the actual current inventory rather than the historical two-default delta | Source, exhaustive-match, semantic, inventory and ABI dimensions remain separate | compatibility |
| S014 | Current capability map requires eighteen M9-003 scenarios | P014,P004,P010,P011 | Separate native auxiliary receipt satisfies strict correspondence | Original seven-scenario receipt remains independent; all eighteen auxiliary cases must PASS, with source/SDK/artifact/log binding | native,identity |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001 | P001 | Existing socket capability regressions and installed observations | Current contract agrees | Constructor defaults are not substituted for factory-specific observed flags | regression,native |
| T002 | S002,S003 | P002,P003 | tools.tests.test_network_capabilities | PASS | Removed operations/conditions/fields/backend/scenarios and doc drift rejected | negative |
| T003 | S004,S005,S006,S007,S008,S009 | P004,P005,P006,P007,P008,P009 | tools/m9_001_native_capabilities.py --offline | All seven native scenarios PASS | Installed public-only consumer, independent peers, resource and typed failure assertions | native |
| T004 | S010,S011 | P010,P011 | Native receipt mutation regressions and real CLI verification | Mutations rejected; clean receipt PASS | No missing execution, stale input, artifact or log is accepted | negative,identity |
| T005 | S012 | P012 | tools.tests.test_m7_linux_task_graph | PASS | Unique 16-task DAG, issue mapping and calculated counts | planning |
| T006 | S013 | P013 | Current API inventory and installed rebuilt consumer | Explicit current classification | Report real additions/removals/changes; old-binary and cross-SDK execution remain NOT_RUN unless exercised | compatibility |
| T007 | S001,S002,S004,S005,S006,S007,S009,S012,S013 | P001,P002,P004,P005,P006,P007,P009,P012,P013 | scripts/check-task M9-001, scripts/check-docs --html and scripts/check | PASS if all actual commands succeed | Architecture, docs, existing protocol/resource regressions remain valid | integration |
| T008 | S014 | P014,P004,P010,P011 | tools/m9_003_native_udp.py --offline through the M9-001 long gate, then strict capability correspondence | All eighteen native scenarios PASS | Preserve M9-003 identity, original 1,800-second limit and output guard; no missing, failed or skipped native case is accepted | native,identity |

## Evidence boundaries

Verify the current P1-015 development baseline before either native gate.
Historical prerequisite results do not qualify changed production or execution
inputs. Capture the auxiliary evidence in the runner's distinct M9-003-owned
`m9-001-current-map` paths without overwriting its canonical evidence or promoting
M9-003 status. Both gates require current source binding and the final evidence seal.
No line/branch coverage, fuzz improvement, formal independent security review,
86,400-second soak, release signature, non-Linux support or system-DNS deployment
matrix is claimed by this task.
