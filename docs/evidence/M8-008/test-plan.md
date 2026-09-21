# M8-008 HTTP consumer contract test plan

Scope: native Linux x86_64 glibc using the selected SDK. Historical M8-007
release, signing and soak conclusions are not requalified or rewritten.
Results below link to executed evidence; the final native gate must pass independently.

## Semantics

| ID | Contract | Expected result |
|---|---|---|
| P001 | Explicit lossless no-follow | 301/302/303/307/308 status, Location and unread body returned unchanged; no target request; maximumRedirects=0 retains its old error semantics. |
| P002 | Controlled cancellation and total deadline | DNS/TCP/TLS/headers/body share one absolute budget; cancellation is idempotent and wakes admitted I/O; no retry after cancellation or expiry. |
| P003 | TLS security defaults | Default trust rejects self-signed peers, custom trust still verifies identity, required mTLS requires client identity, discovered system bundle completes verified handshake. |
| P004 | ResponseBody ownership | Caller reads/closes/drains explicitly; stable EOF, premature EOF detection, exactly-once close and observer, primary failure retained; H2 waits for protocol EOF. |
| P005 | Retry and safe errors | maximumAttempts=1 prevents retry, budgets are per redirect hop, errors retain structured fields without authorization/body/proxy reason secrets. |
| P006 | Server lifecycle | H1/H2 hooks/writes own responses on failure; shared context reaches waits; terminal fanout wakes readers; drain admission is atomic; bounded shutdown and cooperative tasks converge. |
| P007 | Native artifact closure | Identical isolated inputs produce identical raw native/release archives; installed-artifact examples execute HTTPS/no-follow; ELF closure excludes OpenSSL and missing libraries; canonical check runs only in snapshot. |

## Fault-injection matrix

| ID | Injection | Expected result |
|---|---|---|
| S001 | Redirect without or with malformed Location, all five statuses and exhausted old limit | noFollow does not parse, read, drain or close response; default policy remains unchanged. |
| S002 | Condition-gated DNS/TCP and real stalled TLS/header/body reads | Cancelled rather than EOF/timeout; no late connection creation; bounded joins and cleanup. |
| S003 | Stalled body and advancing monotonic clock across DNS/retry/redirect/reads; shorter parent/builder budget; non-positive timeout | Original deadline wins and non-positive timeout rejected before network. |
| S004 | Untrusted chain, wrong identity, required mTLS without identity; test-owned discovered system PEM | Negative handshakes reject before handler; positive mTLS/system trust verify; no secret sentinel leaks. |
| S005 | Premature EOF, completion observer closes stream, simultaneous read/close errors and concurrent reads | Stable EOF, original error priority, at-most-once terminal callbacks and underlying close; closed body rejects new read. |
| S006 | Temporary DNS error, refused single TCP candidate, cross-origin redirect/retry combinations, proxy wire reason/body sentinels | Exact execution counts and per-hop limits; safe structured proxy failure and closed body. |
| S007 | H1 framing failure, H1/H2 after-hook failure, H2 initial HEADERS failure | Produced response body closes even before head commitment; primary error preserved. |
| S008 | H2 request-body stall plus abort/reader EOF/serve cancellation/deadline; flow or writer backpressure | Original context or connection-scope error wakes tasks; no normal EOF or retained listener; bounded task joins. |
| S009 | Drain before first SETTINGS, stream admission racing drain, listener accept-return barriers and repeated shutdown/close | Draining never reopens, GOAWAY includes admitted stream, late transport closed, stopping rejects handlers and cleanup converges. |
| S010 | Real nonzero runner subprocess, timed-out subprocess with descendants, differing raw artifacts, unresolved ELF library, missing pinned source/tool | Fail closed; dependent commands do not run and timeout kills the owned process group; outputs stay in unique task run/evidence roots; no historical cache PASS. |

## Test-plan matrix

| ID | Scenarios | Command or evidence | Result |
|---|---|---|---|
| T001 | P001,S001 | HttpRedirectPolicyTest and HttpFacadeTest no-follow native loopback cases | PASS — [HTTP 101/101](http-tests.json) |
| T002 | P002,S002,S003 | HttpFacadeTest controlled stages and transport_stdnet activity regressions | PASS — [HTTP](http-tests.json), [internal](internal-tests.json) |
| T003 | P003,S004 | HttpFacadeTest TLS cases and tls_engine paired system-trust/mTLS regressions | PASS — [HTTP](http-tests.json), [internal](internal-tests.json) |
| T004 | P004,S005 | HttpMessageTest plus H1/H2 body ownership regressions, failure-first then fixed | PASS — [HTTP](http-tests.json), [internal](internal-tests.json) |
| T005 | P005,S006 | Retry policy, public facade counts and real proxy pipeline negative regressions | PASS — [HTTP](http-tests.json), [internal](internal-tests.json) |
| T006 | P006,S007,S008,S009 | H1 writer/server, H2 mapping/connection/state and public facade lifecycle regressions | PASS — [HTTP](http-tests.json), [internal](internal-tests.json) |
| T007 | P007,S010 | python3 -m unittest discover -s tools/tests -p 'test_m8_008_http_contracts.py' -v | PASS — [6/6](runner-tests.json), [negative gates](negative-gates.json) |
| T008 | P001,P002,P003,P004,P005,P006,P007,S010 | python3 tools/m8_008_http_contracts.py --root . --json, two fresh native builds and installed consumer, snapshot scripts/check | PASS — [native](native-contracts.json), [canonical](canonical-check.json) |

Run complete affected package suites, not a passing filtered subset. Record argv,
cwd, exit code, raw output and pass/fail/skip counts. One-second functional join
bounds do not claim the P99 50 ms performance gate. TCP injection proves phase
propagation, not a real blackhole connect. Non-Linux platforms remain unverified.
