# M7-027 Linux migration and examples evidence

Status: COMPLETE

## Scope

M7-027 adds the maintained Linux migration guide and a checked-in example
program that uses only `wirestack.http` and `wirestack.tls`. The task does not
change public declarations, protocol implementation, SDK components, runtime,
std, or stdx.

The examples cover:

- HTTPS client with a custom CA;
- HTTP/1.1 and HTTP/2 public servers;
- public TLS client/server contexts over a caller-owned bounded transport;
- required client-certificate authentication;
- finite SSE streaming;
- request, connection, and stream cancellation handles;
- explicit CONNECT proxy and origin-TLS configuration.

The CONNECT example validates the public configuration and the separation of
proxy and origin identities. It does not claim interoperability with an
external proxy. M5-021 and M5-022 retain protocol-level CONNECT evidence.

## Native result

[`linux_x86_64/examples.json`](linux_x86_64/examples.json) records a native
Linux x86_64 glibc clean-consumer build and run. The executable printed all nine
required markers after checking status, protocol, payload, TLS identity,
certificate, ALPN, cancellation, retry, shutdown, and resource ownership.

The first sandboxed execution compiled successfully but could not create a
loopback socket because the sandbox returned `Operation not permitted`. The
unchanged gate then passed in the authorized native environment.

## Commands

```text
python3 tools/repository/repository_tooling.py --root . validate-plan docs/evidence/M7-027/test-plan.md --json
python3 -m unittest tools.tests.test_m7_027_linux_examples
scripts/check-m7-027-linux-examples --json
scripts/check-m7-026-linux-api
scripts/check-task M7-027 --json --output docs/evidence/M7-027/task-check.json
scripts/check
scripts/verify-evidence M7-027
```

## Limits

- The one-hour SSE profile and 24-hour final release soak were not run.
- No external proxy or public Internet endpoint was contacted.
- No non-Linux platform evidence was collected.
- The repository API freeze gate is reused; this documentation task adds no
  compatibility claim beyond that gate.

