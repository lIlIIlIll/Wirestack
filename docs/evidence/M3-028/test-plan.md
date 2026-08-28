# M3-028 Linux TLS qualification plan

- Task: `M3-028`
- Profile: native Linux x86_64 glibc only
- Provider: the pinned AWS-LC provider artifact recorded by Wirestack
- Baseline: Cangjie stdx 1.1.3.1 TLS/OpenSSL release asset

ADR-0002 limits this qualification to the current Linux delivery profile.
Windows, macOS, Android, iOS, HarmonyOS, and Linux musl remain outside this
task result. A Linux PASS must not be presented as global M3 completion.

## Traceability matrix

| ID | Requirement | Exercise | Pass rule |
|---|---|---|---|
| T001 | TLS protocol and hostname behavior | Existing real-provider TLS 1.2/1.3, trust, SNI, reference-identity, ALPN, mTLS, session, close and truncation tests | Every selected deterministic test executes and passes |
| T002 | TLS record parser fuzz | Seeded mutation of captured valid TLS records at record boundaries and declared lengths | Every case completes within bounds as accepted input or a typed TLS error; no crash or hang |
| T003 | TLS handshake parser fuzz | Seeded mutation of captured ClientHello and ServerHello flights | Same terminal rule as T002 |
| T004 | Hostname verifier fuzz | Seeded DNS reference and certificate-name corpus including IDNA, wildcard, malformed and boundary inputs | Deterministic result, typed rejection, no crash or hang |
| T005 | Certificate input adapter fuzz | Seeded DER mutation corpus covering truncation, length corruption and bounded random flips | Deterministic result, typed rejection, no crash or hang |
| T006 | External implementation interoperability | Wirestack client to OpenSSL server and OpenSSL client to Wirestack server on loopback, TLS 1.2 and TLS 1.3 | Handshake, negotiated version, application bytes and graceful closure succeed in every direction/version |
| T007 | Dynamic dependency policy | `readelf -d` and `ldd` on the optimized Wirestack test artifact plus provider manifest inspection | No `libssl`, `libcrypto`, stdx TLS FFI or runtime TLS loader dependency; manifest says `externalOpenSslDependency=false` |
| T008 | Bulk throughput | Paired 11-round optimized loopback transfer, at least 1 MiB per sample, Wirestack versus pinned stdx | Wirestack median throughput is at least 90% of stdx |
| T009 | Full handshake latency | Paired 11-round optimized loopback handshakes with the same host certificate and TLS versions | Wirestack P50 is no more than 10% slower and P95 no more than 20% slower than stdx |
| T010 | Resumed handshake | Separate Wirestack session-resumption samples; stdx session availability is probed and recorded | Wirestack resumption is proved by runtime evidence and separate P50/P95 values are retained; no full-handshake substitution or inferred stdx value |
| T011 | Body-size memory scaling | 1 MiB, 16 MiB, 64 MiB and 100 MiB streamed TLS transfers with process-tree RSS sampling | Peak RSS does not scale linearly with payload size; all payloads and raw peaks are retained |
| T012 | Idle TLS library memory | Warm shared contexts, then measure retained-memory deltas across increasing idle connection counts | Regression slope is at most 48 KiB per connection; OS socket buffers and shared-context intercept are excluded and the estimation method is recorded |

## Determinism and fuzz contract

The runner records the PRNG algorithm, seed, corpus digests, mutation count,
maximum input size and per-target timeout. A fuzz target may accept an input or
reject it with a documented typed error. A signal, uncaught foreign exception,
out-of-bounds access, deadlock, timeout, nondeterministic terminal category, or
unbounded allocation fails the gate. This is a bounded release qualification;
M7-006 remains responsible for continuous fuzzing.

## Benchmark method

The gate builds one isolated Wirestack snapshot with `-O2` and compiles the
legacy baseline against the verified stdx 1.1.3.1 archive. It runs one warmup
round followed by 11 paired measured rounds. Pair order alternates each round.
Every raw duration, byte count, negotiated TLS version, resumption flag, exit
code, stdout and stderr is retained. Percentiles use nearest-rank selection.

Both implementations use loopback TCP, the same DER certificate and private
key, the same payload, one client and one server process, and explicit TLS 1.2
or TLS 1.3 configuration. Results from an in-memory Wirestack transport are not
compared with a socket-based stdx baseline.

The body-size profile streams fixed-size chunks and never constructs a payload-
sized Cangjie array. The idle-memory result is a slope across connection counts,
not process RSS divided by connection count. The report preserves the fitted
intercept, samples and residuals so shared contexts and process startup are not
charged to each connection.

## Evidence and failure policy

The formal runner writes under `docs/evidence/M3-028/linux_glibc_x86_64/` and
the task summary under `docs/evidence/M3-028/README.md`. Reports include exact
commands, source and binary digests, provider manifest, stdx archive digest,
compiler, CJPM, kernel, libc, CPU model, affinity and scaling governor.

Missing tools, provider assets, stdx assets, samples, negotiated evidence,
OpenSSL interoperability, dependency metadata or native execution fail the
gate. Thresholds are not weakened and unavailable evidence is not marked as
passed.
