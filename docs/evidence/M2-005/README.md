# M2-005 Linux SystemResolver evidence

- Task: `M2-005`
- Current status: **COMPLETE**
- Linux glibc x86_64 result: **PASS**
- Linux musl result: **DEFERRED_TOOLCHAIN_UNSUPPORTED**
- Compiler: Cangjie `1.1.0-alpha.20260817040003`, `cjnative`
- Executed target: `x86_64-unknown-linux-gnu`

## Implemented scope

`wirestack.http.SystemResolver` owns a fixed native resolver pool. Its public
constructor bounds workers to `1..32` and queued requests to `1..1024`.
`HttpClient.builder().build()` creates and owns this resolver when the caller
does not supply one. A caller-supplied resolver remains caller-owned.

The Linux backend returns IPv4 and IPv6 candidates in native order, removes
duplicates, applies `ResolveOptions.family` and `maxResults`, and reports
`ResolverSource.System`. It leaves `ResolveResult.expiration` empty because
`getaddrinfo` provides no TTL. Native `EAI_*` failures map to stable
`ResolveErrorCode` values. `ResolveException.nativeCode` retains nonzero native
codes without using message text as control flow.

Cancellation and Deadline expiry return before delayed native work completes.
The fixed worker cleans up that work later. `close` rejects new work, waits for
native cleanup, joins each worker, and remains idempotent.

## glibc acceptance

The retained gate compiles an `LD_PRELOAD` fixture with `-O2 -Wall -Wextra
-Werror`. The fixture provides ordered IPv6 and IPv4 candidates, one duplicate,
family filtering, delayed work, and deterministic native errors.

| Criterion | Evidence | Result |
|---|---|---|
| public resolver contract | real `localhost` plus deterministic candidates through `wirestack.http.SystemResolver` | PASS |
| candidate order and deduplication | IPv6 then IPv4; one duplicate removed | PASS |
| result bounds | IPv4 family filter and `maxResults = 1` | PASS |
| TTL handling | every result has `expiration = None` | PASS |
| stable error mapping | name-not-found, no-data, temporary, unsupported-family, and system failure | PASS |
| native evidence | nonzero `EAI_*` values retained; synthetic no-data has no native code | PASS |
| prompt cancellation and Deadline | both return in less than 50 ms against 200 ms native work | PASS |
| lifecycle bounds | constructor limits, idempotent close, and use-after-close rejection | PASS |
| default client integration | `HttpClient.builder().build()` reaches a real loopback `HttpServer` through `localhost` | PASS |
| native calls | 11 complete fixture enter/exit pairs with the expected host counts | PASS |

Retained artifacts:

- [`linux_glibc_x86_64/report.json`](linux_glibc_x86_64/report.json)
- [`linux_glibc_x86_64/resolver-test.log`](linux_glibc_x86_64/resolver-test.log)
- [`linux_glibc_x86_64/integration-test.log`](linux_glibc_x86_64/integration-test.log)
- [`linux_glibc_x86_64/gai-fixture.log`](linux_glibc_x86_64/gai-fixture.log)

The report records Linux `7.1.9-arch1-2`, x86_64, glibc `2.44`, the compiler
target, both test commands, the fixture digest, every native call, and the
per-libc decision.

## musl scope

The installed SDK contains only
`linux_x86_64_cjnative` GNU modules and reports target
`x86_64-unknown-linux-gnu`. `Server` has no `cjc` or `cjpm`. The official
Cangjie 1.0 compiler documentation explains the `musl` triple component but
does not list Linux musl as a supported target from a Linux host.

ADR-0004 limits the current Linux profile to native glibc and defers musl to
P1-011. An Alpine C-only build would test the resolver bridge but would not
execute `SystemResolver` or prove the public Cangjie contract. The musl leg is
neither passed nor failed. It remains outside the current task.

The exact local, remote, and official-document checks are retained in the
[musl target availability record](../../references/cangjie-linux-musl-target-availability-2026-08-27.md).

## Compatibility assessment

The public declaration change is additive: `wirestack.http.SystemResolver` is
new, and all existing public `HttpClient`, resolver capability, and exception
declarations remain available. The internal resolver constructor and lifecycle
helpers are not public API. This is source-, ABI-, and inventory-compatible.

Default `HttpClient` runtime behavior changes intentionally. A client without a
caller-supplied resolver now performs bounded system resolution instead of
failing with `SystemResolverCapabilityException`. The old public capability
enum and exception remain declared so existing source and binaries do not lose
symbols. This semantic change is required by M2-005 and is covered by the real
loopback integration test.

The declaration-level compatibility parser reported the following false
positives: removal of the private `UnavailableSystemResolver`, addition of an
internal method, function-local `let` changes, and addition of a public type
alias. The normative compatibility rules classify a new type alias and a new
public class as compatible; none of the private or local changes alter a frozen
public declaration or object layout. The parser also cannot infer package
visibility and therefore is retained only as a screening signal, not the final
compatibility verdict.

## Commands and exact results

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack scripts/gate-m2-005-system-resolver --output-dir /tmp/wirestack-m2-005-glibc-gate
```

Exit 0. `M2-005-SYSTEM-RESOLVER-GLIBC` reports `PASS` with zero failures.
The resolver suite reports 6 passed cases. The default-client integration
reports 1 passed case. The fixture records 11 complete native calls.

```text
python3 -m unittest tools.gates.tests.test_m2_005_system_resolver
```

Exit 0. Five gate-parser and fail-closed validation tests pass.

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack cjpm build -i
```

Exit 0. The current production packages build successfully.

```text
env DISABLE_ZOXIDE=1 ./scripts/check
```

Exit 0. All Python suites, the architecture guard, native resolver build,
`cjpm check`, and `cjpm build` pass. The final `cjpm test
--exclude-tags=Performance` invocation runs the Cangjie project tests and emits
a complete project summary.

The aggregate result is 548 total cases, 532 passed, 16 skipped, 0 errors, and
0 failed. Package totals are:

| Package | Total | Passed | Skipped | Failed |
|---|---:|---:|---:|---:|
| `wirestack.http` | 66 | 65 | 1 | 0 |
| `wirestack.internal.common` | 9 | 9 | 0 | 0 |
| `wirestack.internal.connector` | 17 | 17 | 0 | 0 |
| `wirestack.internal.http1` | 113 | 110 | 3 | 0 |
| `wirestack.internal.http2` | 148 | 148 | 0 | 0 |
| `wirestack.internal.platform.linux` | 4 | 4 | 0 | 0 |
| `wirestack.internal.resolver` | 11 | 11 | 0 | 0 |
| `wirestack.internal.tls_engine` | 58 | 58 | 0 | 0 |
| `wirestack.internal.transport` | 75 | 75 | 0 | 0 |
| `wirestack.internal.transport_stdnet` | 36 | 24 | 12 | 0 |
| `wirestack.internal.trust` | 9 | 9 | 0 | 0 |
| `wirestack.tls` | 2 | 2 | 0 | 0 |

The 16 skipped cases are performance-tagged profiles. In the restricted
sandbox, the same unittest runner cannot create its local control socket and
fails with `Operation not permitted`; the authorized native Linux run above is
the runtime regression evidence. No product or gate code was changed to work
around the sandbox restriction.
