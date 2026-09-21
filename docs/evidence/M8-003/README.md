# M8-003 evidence

The Linux Unix-domain adapter now preserves pathname and arbitrary-byte
abstract names through `UnixSocketAddress`, with explicit rejection of unnamed
bind targets. Unix stream and datagram loopback tests pass under the same
absolute `OperationContext` and bounded lifecycle rules as TCP/UDP.

Raw sockets are capability-scoped. The M8 Linux artifact has no privileged
native raw adapter, so IPv4, IPv6, AF_PACKET and AF_NETLINK construction fail
closed with `Unsupported`. SOCK_SEQPACKET and ancillary-data APIs remain
explicit exclusions. This is recorded as a BLOCKED capability, not a product
PASS or a claim of raw packet support.

The native network suite passes 16/16 on Linux x86_64 glibc. M8-004 owns DNS
wire/policy work and M8-007 owns final artifact and long-duration evidence.
