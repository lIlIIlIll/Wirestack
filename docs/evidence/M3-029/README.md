# M3-029 public TLS facade

Status: **COMPLETE**

Decision: **PASS**

M3-029 adds the provider-neutral `wirestack.tls` facade required by the PRD.
It exposes immutable client and server contexts, handshakes over a
caller-provided `DuplexTransport`, an owned `TlsConnection`, a `TlsListener`,
negotiated handshake metadata, trust and identity inputs, and stable errors.
No public declaration exposes `std.net`, native AWS-LC handles, OpenSSL
configuration strings, or a legacy TLS socket.

## Ownership and lifecycle

- Starting a handshake consumes the supplied transport.
- Engine creation or handshake failure aborts that transport.
- A successful connection retains its provider for the connection lifetime.
- `TlsConnection` preserves the one-reader/one-writer contract and idempotent
  close/abort lifecycle.
- `TlsListener` passes the caller's `OperationContext` through accept and
  handshake without creating another timeout owner.

## Acceptance evidence

| Check | Result |
|---|---|
| Test plan | PASS: 18 paths, 15 scenarios, 12 tests |
| Public `wirestack.tls` package | PASS: 6/6, 0 skipped |
| Clean path consumer | PASS: build and native execution |
| Real TLS loopback in clean consumer | PASS: HTTP/2 over AWS-LC |
| Public facade construction in clean consumer | PASS: client/server contexts, custom CA and ALPN |
| Architecture guard | PASS: zero violations |
| Public API ownership | PASS: current pre-1.0 inventory has zero internal aliases |

The machine-readable facade report is
[`linux_x86_64/public-tls-facade.json`](linux_x86_64/public-tls-facade.json).
The traceability matrix is [`test-plan.md`](test-plan.md).

## API boundary

M7-032 superseded the historical M7-026 compatibility comparison and moved
user-owned contracts into public packages. M3-029 now verifies the current
pre-1.0 ownership inventory and architecture rules. It does not require source,
API, ABI or semantic compatibility with an earlier experimental snapshot.

## Commands

```shell
python3 -m unittest tools.tests.test_m3_029_linux_tls_facade tools.tests.test_m7_linux_task_graph
scripts/check-m3-029-linux-tls-facade --json
scripts/architecture-guard --format json
scripts/check-task M3-029 --json
scripts/verify-evidence M3-029
scripts/check
```

The restricted sandbox cannot create the Cangjie unittest runner's local
socket. The same test passed in the authorized Linux environment; no product
behavior was changed to work around the environment restriction.

## Excluded gates

No SDK was built. No runtime, `std`, `stdx`, or SDK repository was modified.
The 24-hour soak, one-hour SSE profile and every non-Linux platform gate were
not run and are not completion evidence for M3-029.
