# M8-007 evidence

M8-007 is the Linux x86_64 glibc release-candidate closure for the M8 network
foundation. It rebuilds the source-plus-pinned-native artifact, checks
reproducibility and installation, regenerates the current public API baseline,
and binds the SPDX/provider/license/NOTICE sidecars to the exact artifact
digest. Security validation also rejects system OpenSSL dependencies, loader
strings, unsafe archive members and stale sidecars.

The candidate retry after the first long-gate failure also includes a narrow
cancellation-scope repair: HTTP/1 connection establishment retains the full
operation context, while HTTP/2 stream execution receives a context without
the selected connection token and binds that token once for connection fan-out.

The final candidate additionally makes connection cancellation one-shot per
HTTP/2 connection. It marks the connection unavailable and terminates affected
streams synchronously, while the abort/transport cleanup runs once in a bounded
background task. Pool discard and explicit close still force the same abort
path, so cancellation cannot re-admit a connection or leave it reusable.

The final soak is deliberately separate from development checks. A task or
full check cannot select it implicitly. `final-soak-validation.json` is valid
only when the native candidate has run for at least 86,400 seconds and all
workload/resource/terminal-owner checks are PASS. A short preflight is useful
for diagnosing the harness but is not release evidence.

This task remains Linux-only and does not build the SDK or modify runtime,
`std`, `stdx` or any non-Linux provider. The final report records any unrun
platform gates and non-claims explicitly.

The final artifact is `dist/m8-007/wirestack-0.1.0-linux-x86_64-glibc.tar.gz`
with archive SHA-256
`f9a75fa3f508b34b79760a330c369707839f03945e598478d24559ec0ddecd97` and
payload SHA-256
`96ca9607c36d1a26e577d661b592bcd0c88d9dd0b459910723da601a69c24785`.
The native task gate passed 77/77 HTTP tests and the final candidate soak ran
86,400.041 seconds, completed 858,163 cycles and 107,271 connection
cancellations, joined 1,716,326 spawned tasks, retained zero terminal owners,
and recorded a maximum cancellation latency of 16.46 ms against the 50 ms
limit. Resource, heap, FD, socket, waiter, timer, thread and process-tree
trends all passed.
