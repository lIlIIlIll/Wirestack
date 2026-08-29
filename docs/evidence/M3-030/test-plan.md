# M3-030 test plan

## Semantics

M3-030 makes provider selection a build-time decision independent of the target
platform. Generic TLS and HTTP code consumes a Wirestack-owned `TlsProvider`
contract. The selected adapter owns native ABI calls and returns opaque engines.
Linux x86_64 glibc selects the pinned AWS-LC 5.5.0 adapter. Unknown, incompatible,
or incomplete selections fail closed without probing libraries or falling back.

Contexts, engines, connections, sessions, and factories retain one provider
instance identity. Cross-provider use is rejected before native work. Provider
close and connection close or abort are idempotent, and each operation reaches at
most one terminal result. Stable errors retain classification, phase, retryability,
native status when present, and cause without parsing exception messages.

## Control-flow path matrix

| Path ID | Conditions and values | Runtime/compiler checks | Reachability | Notes |
|---|---|---|---|---|
| P001 | known Linux platform and default provider | selection schema and matrix | reachable | Select AWS-LC 5.5.0 at build time. |
| P002 | unknown platform | selector validation | reachable error | Return `unsupported-platform`; no adapter runs. |
| P003 | known platform and unknown provider | selector validation | reachable error | Return `unsupported-provider`; no fallback. |
| P004 | known values but disallowed pair | matrix constraint | reachable error | Fail `unsupported-combination`. |
| P005 | provider manifest absent | manifest loader | reachable error | Fail before source or build access. |
| P006 | unknown manifest schema or field | JSON schema validator | reachable error | Reject deterministically. |
| P007 | provider ID, version, source digest, tag, commit, or tree differs | pin validator | reachable error | Reject the adapter input. |
| P008 | ABI version differs or required symbol is absent | ABI validator and archive scan | reachable error | Reject build output. |
| P009 | capability requires an absent ABI function | capability-function validator | reachable error | Reject false capability claims. |
| P010 | selected adapter initializes | provider factory | reachable | Return provider-neutral provider. |
| P011 | provider initialization fails or returns invalid state | provider factory | reachable error | Preserve stable provider failure. |
| P012 | client or server context creation succeeds | provider contract | reachable | Bind context to provider instance. |
| P013 | context creation fails | provider contract | reachable error | No engine or connection escapes. |
| P014 | client or server connection creation succeeds | provider contract | reachable | Retain provider for connection lifetime. |
| P015 | connection creation fails | provider contract | reachable error | Release engine and transport once. |
| P016 | context, engine, connection, or session identities differ | binding check | reachable error | Reject before native use. |
| P017 | provider close requested while contexts or connections exist | ownership check | reachable | Existing owners remain valid; final release waits. |
| P018 | repeated provider, engine, connection close or abort | terminal claim | reachable | First terminal wins; cleanup once. |
| P019 | cancellation races native completion | operation completion | reachable | Exactly one result and cleanup. |
| P020 | native status is known | error mapper | reachable error | Stable code, phase, retryability and native code. |
| P021 | native status or engine step is unknown | fail-closed mapper | reachable error | Provider failure; no message parsing. |
| P022 | test provider enters the same factory | injected factory | test-only | Core and facade operate without AWS-LC types. |
| P023 | test provider enters release payload | artifact validator | reachable error | Reject artifact. |
| P024 | generic TLS, HTTP or build code references AWS-LC | architecture guard | reachable error | Stable rule and source coordinate. |
| P025 | future adapter registration is simulated | synthetic selection matrix | test-only | No generic TLS or HTTP file changes. |
| P026 | selected provider changes after evidence sealing | evidence freshness | reachable error | Artifact, SBOM and reports become STALE. |
| P027 | release manifest and SBOM are generated | selected manifest | reachable | Record actual platform, provider, ABI and licenses. |
| P028 | default artifact dependency scan runs | archive and binary scan | reachable | No system OpenSSL or test provider. |
| P029 | `build.cj` invokes the generic entrypoint | source guard | reachable | No AWS-LC path or argument. |
| P030 | fast, full or task gate is selected | task manifest | reachable | No long gate is included. |
| P031 | production Cangjie imports a TLS native function absent from the canonical ABI contract | source-to-contract validator | reachable error | Reject with `abi-contract-incomplete` before accepting an archive. |
| P032 | Cangjie FFI or native header changes a parameter, return type, or calling convention | signature contract and compiled header probe | reachable error | Reject before provider acceptance with a stable signature mismatch code. |

## Input-domain partitioning

| Domain | Partitions and boundaries | Cross-constraints |
|---|---|---|
| platform | Linux glibc x86_64; unknown; future synthetic adapter | Only Linux AWS-LC is production-supported. |
| provider | default AWS-LC; explicit AWS-LC; unknown; test-only | Test provider cannot enter release payload. |
| manifest | valid; missing; malformed; schema 0/1/2; extra field; wrong pin | Schema 1 and exact pin are required. |
| ABI | provider version 0/1/2; contract schema 1/2/3; full symbols; one missing symbol; false capability; production import omitted from contract; parameter/return/calling-convention drift | Provider ABI 1, contract schema 2, every production import, signature and capability-required function are required. |
| lifecycle | new; context-owned; connection-owned; close requested; closed | Provider survives all retained owners. |
| terminal operation | success; cancellation; deadline; close; abort; native failure | Exactly one terminal result and cleanup. |
| evidence | current; missing report; changed digest; changed selected provider | Any drift invalidates PASS. |

## Semantic scenario matrix

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|---|
| S001 | default Linux selection | valid matrix | P001,P010 | AWS-LC adapter is selected at build time | exact platform, provider, version, ABI and capabilities | normal,platform | P0 |
| S002 | unknown platform | no adapter selected | P002 | fail closed | stable code and zero adapter invocation | negative | P0 |
| S003 | unknown or disallowed provider | known/unknown platform | P003,P004 | fail closed without AWS-LC fallback | stable code and selected provider absent | negative | P0 |
| S004 | missing or unknown manifest | selected adapter | P005,P006 | build stops before native work | deterministic schema/path issue | negative | P0 |
| S005 | ID/version/source pin mismatch | schema-valid manifest | P007 | build stops | exact mismatched field reported | negative,supply-chain | P0 |
| S006 | ABI mismatch or missing function | built archive | P008,P009 | artifact rejected | ABI/symbol/capability issue reported | negative,abi | P0 |
| S007 | provider initialization succeeds/fails | selected factory | P010,P011 | neutral provider or structured failure | identity, cause and native status retained | normal,error | P0 |
| S008 | client/server context create succeeds/fails | live provider | P012,P013 | bound immutable context or clean failure | binding and no escaped engine | lifecycle | P0 |
| S009 | client/server connection create succeeds/fails | bound context | P014,P015 | provider retained or resources released once | connection identity and cleanup counters | lifecycle | P0 |
| S010 | objects from two providers are mixed | two live providers | P016 | reject before native call | stable mismatch code and native-call count zero | negative,lifecycle | P0 |
| S011 | provider close while connection is active | retained owner | P017 | active connection remains valid | final provider cleanup after owner release | lifecycle | P0 |
| S012 | repeated close and abort | any open/terminal object | P018 | first terminal wins | cleanup count exactly one | lifecycle | P0 |
| S013 | cancellation and completion race | active native operation | P019 | exactly one terminal | one result, one cleanup, no waiter | concurrency | P0 |
| S014 | known/unknown native error or state | active operation | P020,P021 | stable mapped failure | category, phase, retryability, native code and cause | error | P0 |
| S015 | TestTlsProvider factory injection | test build | P022 | TLS Core and facade use test identity | context, connection and result show test provider | substitution | P0 |
| S016 | test provider in default artifact | release assembly | P023 | artifact rejected | no test-provider symbol or manifest | negative,release | P0 |
| S017 | forbidden AWS-LC reference in generic code | synthetic source | P024 | guard fails | stable rule and exact path | architecture | P0 |
| S018 | simulated future platform adapter | synthetic matrix | P025 | registration succeeds without generic changes | generic source digest unchanged | architecture | P1 |
| S019 | provider or input changes after PASS | sealed evidence | P026 | old evidence becomes STALE | changed source digest named | evidence | P0 |
| S020 | Linux release metadata | selected AWS-LC manifest | P027,P028 | manifest, SBOM, licenses and scan pass | actual provider fields, LICENSE/NOTICE, no OpenSSL | release | P0 |
| S021 | generic build entrypoint | production build files | P029 | selector dispatches to Linux adapter | no AWS-LC token in `build.cj` | build | P0 |
| S022 | task/fast/full selection | M3-030 manifest | P030 | bounded commands only | no long-running command selected | task-contract | P0 |
| S023 | peer-verification import is absent from contract or archive | production source plus selected provider | P008,P031 | fail closed before provider acceptance | contract omission and archive omission have distinct stable codes | negative,abi,security | P0 |
| S024 | provider-destroy FFI or header uses incompatible parameter and return types | schema-v2 signature contract | P008,P032 | fail closed before build acceptance | Cangjie and native mismatches have distinct stable codes; C convention is required | negative,abi,security | P0 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001,S002,S003 | P001,P002,P003,P004 | selection matrix fault table | exact selection or stable rejection | platform/provider/error/fallback assertions | unit |
| T002 | S004,S005 | P005,P006,P007 | manifest mutations | every mutation rejected | stable issue field and bounded output | fault-injection |
| T003 | S006 | P008,P009 | ABI/symbol/capability mutations | every mismatch rejected | version, function and capability assertions | fault-injection |
| T004 | S007 | P010,P011 | native and injected factories | provider or structured failure | identity, cause, native status | unit |
| T005 | S008,S009,S010 | P012,P013,P014,P015,P016 | two providers and contexts | valid objects work; mixed objects fail | binding and native-call counters | unit,lifecycle |
| T006 | S011,S012 | P017,P018 | retained connection and repeated terminals | deferred provider cleanup and one terminal | cleanup counters exactly one | unit,lifecycle |
| T007 | S013 | P019 | deterministic completion/cancel orders | one terminal for each order | result, waiter and cleanup assertions | concurrency |
| T008 | S014 | P020,P021 | known and unknown native states | stable provider error | classification fields and cause | unit,error |
| T009 | S015 | P022 | TestTlsProvider via common factory | facade handshake succeeds | test identity and connection result | substitution,integration |
| T010 | S016 | P023 | artifact containing test marker | validation fails | marker/path reported | fault-injection,release |
| T011 | S017 | P024 | forbidden references in TLS/HTTP/build files | architecture guard fails | stable rule IDs and coordinates | fault-injection,architecture |
| T012 | S018 | P025 | synthetic future adapter registration | selector accepts test combination | generic TLS/HTTP digests unchanged | structural |
| T013 | S019 | P026 | sealed evidence plus provider mutation | STALE | changed provider source named | evidence |
| T014 | S020 | P027,P028 | Linux release candidate metadata | PASS | platform/provider/ABI/license/SBOM/dependency assertions | release |
| T015 | S021 | P029 | `build.cj` and generic build driver | PASS | no AWS-LC tokens; generic entrypoint present | static |
| T016 | S022 | P030 | task manifest through repository tooling | PASS | no long command and bounded timeout | static |
| T017 | S001,S007,S020 | P001,P010,P027,P028 | real AWS-LC TLS 1.2/1.3 and ALPN suite | PASS | handshake, HTTPS, H2, mTLS, session and cancellation | native,integration |
| T018 | S015,S017 | P022,P024 | clean consumer and public inventory | PASS | no provider/native/internal public exposure | integration,architecture |
| T019 | S023 | P008,P031 | production import inventory, incomplete contract and archive without peer-verification | FAIL/PASS | all 55 imports are covered; omissions return `abi-contract-incomplete` or `abi-function-missing` | unit,fault-injection,security |
| T020 | S024 | P008,P032 | mutate provider-destroy from `(UInt64): Unit` to `(Int32): UInt64`, mutate native header, contract schema and calling convention | FAIL | FFI returns `abi-signature-mismatch`; header returns `native-abi-signature-mismatch`; schema/calling convention fail closed | unit,compile-probe,fault-injection,security |

## Evidence and excluded gates

The task records raw bounded output and machine-readable reports under this
directory. It makes no Windows, Apple, Android, HarmonyOS, musl, pure Cangjie
provider, one-hour SSE, or 86,400-second soak claim. Coverage, mutation and
non-Linux platform evidence are not provided and are not inferred.

## Gap review

- Native Windows, Apple, Android and Harmony provider behavior is
  `evidence-insufficient`; this task only proves that an adapter can be
  registered without changing generic TLS or HTTP code.
- Linux musl is `evidence-insufficient` because the installed Cangjie SDK has no
  supported musl target.
- Coverage and mutation adequacy are not claimed because this task does not
  produce cjcov or mutation artifacts.
- The one-hour SSE profile and 86,400-second release soak remain explicit later
  gates and cannot be inferred from bounded M3-030 tests.
