# Wirestack M7-029 independent security review

## Identity and target

I am `OpenAI Codex isolated reviewer /root/m7_029_independent_review`, an OpenAI Codex review subagent commissioned by the same repository owner. I had no implementation role, used a clean detached snapshot, inherited no implementation discussion, and did not ask the implementation agent for conclusions. This is process isolation, not organizational independence from the commissioning owner.

- Commit: `e19cd8e4a07e84e4da0a0a8648919b86e08684f8`
- Package: `docs/security/review/linux-1.0/evidence-index.json`
- Verified SHA-256: `19257a4f9d8571cdaea069beb571efa0e36e660563b25d90a83ce54345078b6c`
- Review interval: `2026-08-29T02:25:00Z` to `2026-08-29T03:08:14Z`
- Decision: **FAIL**. Open Critical and High findings block release.

## Scope and methods

I covered every requested scope item: certificate identity; DNS and proxy routing; HTTP/1 framing and smuggling; HTTP/2, HPACK, SETTINGS, and flow control; cancellation, close, and exactly-once lifecycle; Linux transport and resolver behavior; native TLS and resolver C ABI; pool isolation; private keys; release evidence; resource bounds; sensitive-data handling; supply chain; and TLS protocol state.

Methods used were evidence audit, native C ABI inspection, and source review, supplemented by bounded builds, tests, negative/fault-injection tests, and loopback integration execution. I inspected the public ownership inventory, architecture guard, AWS-LC manifest and build code, certificate verification/session partition code, key loading, HTTP/1 shared framing, HTTP/2 frame/HPACK/state machines, resolver and StdNet adapters, pool keys, retry accounting, workflows, evidence index, and release status.

No new HTTP/1 request-smuggling bypass, HPACK dynamic-table bound escape, certificate SAN/CN fallback, secret-bearing report content, OpenSSL runtime fallback, or private runtime ABI call was found in the inspected paths. These observations do not override the open findings below.

## Findings

| ID | Severity | Status | Summary |
|---|---|---|---|
| WS-CI-001 | Critical | Open | Ordinary PR checks do not require a complete clean native build and full Cangjie test gate. |
| WS-BUILD-002 | High | Open | Clean CJPM lifecycle builds AWS-LC but omits the required resolver archive. |
| WS-H2-SERVER-FLOW-001 | High | Open | Server consumes DATA flow credit before queue admission succeeds. |
| WS-H2-SETTINGS-001 | High | Open | Peer defaults and local advertised SETTINGS are conflated and incomplete. |
| WS-H2-WRAP-001 | High | Open | Cancellation wrapper restores Content-Length early-completion on an H2 body. |
| WS-PROXY-001 | High | Open | HTTPS CONNECT pool partition omits proxy credential identity. |
| WS-RES-001 | High | Open | Active `getaddrinfo` is not cancellable and blocks resolver destruction. |
| WS-RETRY-001 | High | Open | A timed-out partially committed write can be classified retryable with zero recorded bytes. |
| WS-STDNET-001 | High | Open | Cancelling one `accept` closes the shared listener. |
| WS-TLS-TRUST-001 | High | Open | Same-size bundle changes and trust-directory changes do not alter session partition identity. |
| WS-LIC-001 | High | Open | The release snapshot has no explicit Wirestack license grant. |
| WS-API-001 | Medium | Open | `ByteSpan` documents immutability while exposing mutable array storage. |
| WS-CANCEL-001 | Medium | Open | Public cancellation callback storage has no hard bound. |
| WS-CI-SUPPLY-001 | Medium | Open | CI actions use mutable major-version tags. |
| WS-H2-BUFFER-001 | Medium | Open | Inbound H2 buffering is coupled to an outbound segment count and lacks an independent byte cap. |
| WS-H2-SETTINGS-002 | Medium | Open | SETTINGS application does not enforce endpoint-role rules for `ENABLE_PUSH`. |
| WS-IPV6-001 | Medium | Open | URL parsing accepts IPv6 literals but direct client factories convert them to `HostName`. |
| WS-TLS-KEY-001 | Medium | Open | PKCS#8 metadata validation and reading are separate path operations. |
| WS-TLS-OWN-001 | Medium | Open | A built TLS context depends on a caller-closeable `PrivateKeyRef`. |
| WS-EVID-002 | Medium | Open | Seven release entries are stale after M7-032 and the exact snapshot does not pass the repository/task gates. |

The machine-readable report contains affected locations, reproduction steps, impact, evidence, and disposition for every reported finding.

## Validation evidence

Commands were run from the clean detached repository unless noted.

| Command | Exact result |
|---|---|
| `sha256sum docs/security/review/linux-1.0/evidence-index.json` | PASS; exact requested digest. |
| `git rev-parse HEAD` and `git status --short` | Exact target commit; initially clean and no tracked/untracked source changes after review. Ignored build outputs were produced. |
| `scripts/check-m7-028-security-review --json` | PASS; 11 documents, 12 evidence entries, 4 current, 1 historical, 7 stale-after-M7-032. |
| `scripts/check-task M7-028 --json` | PASS; test-plan validation, 8 fault-injection tests, and package validation passed. |
| `scripts/verify-evidence M7-028` | PASS. |
| `scripts/architecture-guard --format json` | PASS; zero violations. |
| `scripts/check-m7-032-public-api --json` | PASS; 243 declarations and zero internal aliases. |
| `scripts/check-m7-032-clean-consumer --json` outside the restricted socket sandbox | PASS; all nine documented example markers passed. |
| Clean `cangjie_env dynamic; cjpm check` | FAIL after AWS-LC build: required `wirestack_resolver` library missing. |
| `python3 tools/build_linux_resolver.py --root .` followed by `cjpm check` | PASS; demonstrates the omitted prerequisite and confirms source compiles once supplied. |
| `scripts/check` | FAIL; Python suite ran 154 tests with 9 failures and 4 errors, principally committed evidence/status drift after M7-032. It did not establish a green Cangjie gate. |
| `scripts/check-task M7-032 --json` | FAIL; status-expectation test, restricted-sandbox clean consumer, and Cangjie test stage failed. Its architecture and public-inventory subchecks passed. |
| Escalated `cangjie_env dynamic; cjpm test` | FAIL; 584 total, 579 passed, 5 errors, 0 assertion failures. The errors were native network/profile/benchmark packages; this is not recorded as PASS. |
| Initial restricted-sandbox `cjpm test` | ERROR due to `Operation not permitted` on local sockets; not counted as product evidence. |

Two exploratory command forms were invalid and are not evidence: a nonexistent `scripts/validate-m7-028-test-plan.py`, and `scripts/architecture-guard --json` instead of `--format json`. The canonical M7-028 task command and corrected architecture command were subsequently executed as shown above.

## Prior audit reassessment

The earlier `49f3094` audit was treated only as a lead list.

- Fixed on this snapshot with executed checks: `WS-BUILD-001` (the pinned provider manifest now exists and provider construction succeeded), and `WS-API-ALIAS-001` (public inventory and architecture guard passed). `WS-BUILD-002` is a distinct resolver build-lifecycle defect.
- Independently reconfirmed and reported above: `WS-CI-001`, `WS-LIC-001`, `WS-H2-SERVER-FLOW-001`, `WS-H2-SETTINGS-001`, `WS-H2-WRAP-001`, `WS-PROXY-001`, `WS-RES-001`, `WS-RETRY-001`, `WS-STDNET-001`, `WS-TLS-TRUST-001`, `WS-API-001`, `WS-CANCEL-001`, `WS-CI-SUPPLY-001`, `WS-H2-BUFFER-001`, `WS-H2-SETTINGS-002`, `WS-IPV6-001`, `WS-TLS-KEY-001`, and `WS-TLS-OWN-001`. The prior `WS-EVID-001` concern is represented by the exact-snapshot `WS-EVID-002` evidence finding.
- Reassessed as plausible code-quality or lifecycle leads but not promoted without sufficient independent bounded reproduction in this report: `WS-CONN-001`, `WS-H2-BODY-001`, `WS-H2-DRAIN-001`, `WS-H2-WRITER-001`, `WS-POOL-001`, `WS-RES-002`, `WS-RES-003`, `WS-TIME-001`, `WS-TLS-CLOSE-001`, `WS-TLS-LIFE-001`, `WS-TLS-PROFILE-001`, `WS-TLS-SESSION-001`, `WS-CONN-002`, `WS-HTTP1-PERF-001`, `WS-RES-004`, `WS-STDNET-002`, `WS-STDNET-003`, `WS-TLS-SOURCE-001`, and advisory `WS-H1-CONNECT-001`. This does not assert they are fixed.
- Not verifiable from the detached repository snapshot: `WS-GOV-001` live GitHub branch protection and `WS-PR41-001` unmerged PR behavior. They remain outside this report's closure claim.

## Limits

I did not run the one-hour SSE profile, the 86,400-second final soak, SDK builds, or non-Linux platform gates, as required by the commission. I did not verify live GitHub branch protection, required checks, remote Actions, signed artifacts, or an external consumer registry. The five Cangjie test errors were not isolated into individual product defects during this bounded review. No finding is marked Fixed solely from static reading.

This report does not claim M7-029 completion. The repository owner must validate the report schema and independently drive remediation and regression closure.
