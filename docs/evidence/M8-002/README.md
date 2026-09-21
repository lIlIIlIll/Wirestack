# M8-002 evidence

M8-002 implements the Linux x86_64 glibc synchronous TCP and UDP surface over
the provider-neutral Transport SPI. TCP and Unix stream backends use bounded
20 ms readiness polling, preserve partial progress, expose explicit
`readExact`/`writeAll` helpers and enforce one active reader and writer. Close,
abort, cancellation and deadline paths are kept distinct and close is
idempotent. UDP receives allocate a one-byte sentinel so truncation is reported
only when the message really exceeds the caller capacity; sends reject the
protocol maximum before writing.

The native `wirestack.net` suite passes 16/16 on Linux x86_64 glibc with socket
permission enabled. It covers loopback TCP, cancellation, close wakeup,
directional exclusivity, UDP atomicity/truncation and payload bounds. The
restricted sandbox's `Operation not permitted` socket error is an environment
signal and is not recorded as a product failure or a false PASS.

M8-003 owns Unix-domain and raw capability completion, M8-004 owns DNS wire
transport and resolver policy, and M8-007 owns the final artifact and 86,400 s
candidate soak. No long-duration gate was run here.
