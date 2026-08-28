# M1-007 Linux network-error evidence

## Status

- Task: `M1-007`
- Linux x86_64 glibc: **COMPLETE**
- Other platforms: **NOT RUN**

M1-007 qualifies the transport error model required by PRD section 16.1 on
Linux.

## Dependency decision

M1-001 is complete and has retained Linux evidence. Global M0-019 remains
blocked by non-Linux gates. ADR-0002 permits Linux tasks once their matching
Linux decisions are satisfied, without changing the global status. PRD section
16.1 fixes the error fields used by this task.

## Acceptance mapping

| Criterion | Evidence | Result |
|---|---|---|
| Stable classification coordinates | `retainsStableClassificationAndEndpointEvidence` observes category, phase, code, and retryability without inspecting message text. | PASS |
| Optional native code is expressible | The same test retains native code 111. `retainsLocalEndpointCauseAndOptionalDefaults` proves the field is `None` when unavailable. | PASS |
| Both endpoints are expressible | The first test retains a remote endpoint. The second retains a local endpoint while the remote endpoint remains absent. | PASS |
| Cause is retained | `retainsLocalEndpointCauseAndOptionalDefaults` passes an underlying exception and observes the same diagnostic text through `cause`. | PASS |
| Unknown retryability is fail-closed by default | The second test omits retryability and observes `Retryability.Unknown`. | PASS |
| Error text is diagnostic, not a classification key | Callers classify the public enum fields. `NetworkException` retains its message only through the normal exception string. | PASS |
| HTTP error status is not a transport exception | `received4xxAnd5xxRemainHttpResponses` decodes 404 and 500 responses, exposes each status on `HttpResponse`, and reads each empty body normally. | PASS |

The implementation already met the task contract. This task adds the missing
optional-field, local-endpoint, cause, and HTTP-status separation tests.

## Commands and results

```bash
/home/elliot/.codex/scripts/codex_cangjie_env cjpm test \
  --filter='NetworkErrorTest.*,Http1ResponseReaderTest.received4xxAnd5xxRemainHttpResponses' \
  --no-color --no-progress
```

Result: both `NetworkErrorTest` cases and the HTTP status-separation case passed.
Project totals were 3 passed, 566 skipped, 0 failed, and 0 errors. Exit status
0.

```bash
/home/elliot/.codex/scripts/codex_cangjie_env scripts/check
```

Result: exit status 0. The command passed 57 repository tool tests, 114 gate
tool tests, 23 benchmark tool tests, the architecture guard, `cjpm check`, and
`cjpm build`. Non-performance Cangjie totals were 549 passed, 20 skipped, 0
failed, and 0 errors. The existing compiler warnings for `metrics`,
`waitUntilAcceptActive`, and `waitUntilWaiters` remain unrelated to M1-007.

## Scope limits

- No public declaration or production behavior changed.
- Global M0-019 remains blocked; this evidence closes only the Linux M1-007
  task.
- No runtime, std, or SDK source was modified.
- No SDK component was built.
- Runtime and std enhancements are optional future work, not Wirestack release
  dependencies.
- Non-Linux platforms were not executed.
