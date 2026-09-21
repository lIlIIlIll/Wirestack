# M8-001 evidence

M8-001 freezes the Linux x86_64 glibc public network-foundation contract. It
adds the Wirestack-owned `wirestack.net` package, a bounded public-API bridge
to the existing Transport SPI, explicit Unix/raw capability boundaries and
the initial HTTP parity hook types. The dependency direction remains:

```text
wirestack.http -> wirestack.tls -> wirestack
       |               |
       v               v
internal HTTP -> internal TLS -> internal Transport SPI <- std.net adapter
```

The installed SDK does not expose a byte-address Unix constructor or a native
privileged raw adapter. Abstract Unix operations, Unix datagram byte-address
sends and actual raw packet I/O therefore remain Unsupported/NOT_RUN; they are
not recorded as successful capability evidence. AF_PACKET, AF_NETLINK,
SOCK_SEQPACKET and ancillary-data APIs are explicit M8 exclusions.

Validation was performed on Linux x86_64 glibc with the repository Cangjie
toolchain. `cjpm check` and `cjpm build` pass. The `wirestack.net` contract
suite passes 5/5 cases, and the complete `wirestack.http` package passes 75/75
cases, including the four parity cases. The public network test command is
expected to require a native socket-capable runner; the restricted local
sandbox's `Operation not permitted` socket error is retained as environment
evidence and is not treated as a product pass.

The bounded stdout/stderr captures from the task gate are retained beside the
JSON reports (for example `network-contract-tests.stdout.log` and
`http-parity-tests.stdout.log`). They are diagnostic inputs, not independent
PASS claims; the indexed JSON reports remain the acceptance record.

Long-running profiles are deliberately not run. M8-007 owns the final release
artifact, regenerated evidence and one 86,400-second candidate soak.
