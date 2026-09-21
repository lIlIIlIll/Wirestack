# M8-004 evidence

The Linux resolver now has a bounded DNS wire parser and explicit client path:
queries use one transaction identity, validate the question and responding
nameserver, retry a bounded nameserver/attempt set, and switch from truncated
UDP to length-framed TCP under the same absolute `OperationContext`. A/AAAA
answers, CNAME chains and selected SRV/TXT/MX/PTR records are length-checked;
compression loops, reserved encodings and malformed RDATA are rejected.

`Resolver` applies a capped search/`ndots` candidate order and a bounded,
configurable hosts file before DNS. Hosts entries support IPv4 and IPv6,
preserve `ResolverSource.HostsFile`, and invalid/oversized files are ignored.
Positive and negative cache entries have finite lifetimes; empty address answers
are not cached as successful results. The connector remains responsible for
Happy Eyeballs while consuming this result under the same context.

The native Linux network/DNS suite passes 19/19, including a real local UDP
truncation-to-TCP fallback. No long-duration gate was run.
