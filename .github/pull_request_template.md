## Task

- Task ID:
- Issue:
- PRD references:
- Dependency evidence:

## Scope

What changed, and what explicitly did not change?

## Architecture checklist

- [ ] Only the StdNet adapter imports `std.net`, or this PR does not touch that boundary.
- [ ] Public/Core APIs do not expose `std.net` or provider-native types.
- [ ] No `CJ_MRT_Sock*` private ABI use.
- [ ] No second timeout owner was introduced.
- [ ] New queues/buffers/caches/windows/pools have explicit bounds.

## Lifecycle / error checklist

- [ ] exactly-once completion tested where applicable.
- [ ] close/abort idempotence tested where applicable.
- [ ] cancellation/timer/waiter registrations are cleaned up.
- [ ] Errors preserve stable category/phase/code/retryability and do not parse message text.

## Verification

List exact commands and exit status. Mark unavailable/skipped tests as NOT RUN,
not PASS.

```text
<commands and results>
```

## Evidence

- `docs/evidence/<TASK-ID>/...`
- Gate report:
- Benchmark:
- Fuzz:
- Native device/VM:
- Upstream issue/PR:

## Risks / follow-up

- Remaining risks:
- Next READY task(s):
