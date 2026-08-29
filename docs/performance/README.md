# Performance evidence

Performance claims are valid only for the exact source, toolchain, host,
commands and thresholds retained by the owning task. Ordinary unit tests and a
single timing sample are not qualification.

## Current Linux coverage

- [HTTP/1 keep-alive and streaming](http1-benchmark.md)
- [HTTP/2 concurrency and connection ownership](http2-benchmark.md)
- [M7-024 aggregate Linux gate](../evidence/M7-024/README.md)
- [M1-027 OperationContext profile](../evidence/M1-027/README.md)

M7-024 binds seven raw reports to the qualified production-source fingerprint
and checks raw TCP, DNS, TLS, HTTP/1, HTTP/2, cancellation, SSE and memory.
Historical results remain evidence for their recorded source; source drift does
not inherit their pass.

## Run policy

Performance commands are explicit and may contend for host resources. They are
not selected by `scripts/check`, `scripts/check-fast` or `scripts/check-full`.
Use the task manifest and evidence README for the exact command and environment.
Do not run a long profile merely to validate a documentation change.

Report raw samples, warmups, ordering, percentile method, RSS/FD scope,
baseline identity and the final threshold decision. State when a benchmark uses
memory transport and therefore does not measure sockets, TLS or the Internet.
