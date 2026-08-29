# Architecture and trust boundaries

The enforced dependency direction is:

```text
HTTP -> TLS -> Transport SPI <- StdNetTransport -> std.net
```

Only the standard-network adapter may import `std.net`. HTTP, TLS, public
contracts, protocol state machines, provider handles, and native platform
details remain separated by architecture guards. Public packages own all types
that users construct, pass, match, or catch; internal packages own protocol and
provider implementation.

One `OperationContext` carries one monotonic absolute deadline and one
cancellation token across DNS, TCP, proxy, TLS, headers, and body work. Close
and abort are idempotent, and each operation has one terminal completion.

The principal trust boundaries are application to public API, public API to
protocol core, protocol core to transport SPI, transport adapter to `std.net`,
TLS engine to provider C ABI, and provider to the pinned cryptographic library.
See ADR-0001 through ADR-0006 for the accepted physical and ownership model.

