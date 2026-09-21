# M8-006 evidence

M8-006 makes Linux TLS contexts immutable snapshots with explicit context
epochs. `TlsClientContextStore` and `TlsServerContextStore` replace only the
snapshot used by future handshakes; a connection and its session state retain
the epoch captured at creation. Client session keys and server session identity
material include that epoch, so trust, identity and security-policy replacement
cannot reuse stale resumption state.

`ExternalDecryptor` and `KeyLogSink` are provider-neutral, bounded public
contracts. The callback receives the handshake `OperationContext` supplied by
the caller. No callback creates a second timeout owner. Key logging is an
explicit test/debug hook and is not implicitly enabled in the Linux release
provider.

Native Linux evidence covers the selected AWS-LC provider through the existing
provider-neutral TLS facade, context/session tests, architecture guard and a
clean public consumer. The provider-specific implementation remains behind the
build-time factory; no public declaration or TLS core file imports an AWS-LC
type. Non-Linux execution, the one-hour SSE profile and the 86,400-second
candidate soak are not part of this task; M8-007 owns the final artifact and
long gate.

The JSON reports in this directory are generated atomically by the repository
task tooling and are bound to the source paths and toolchain used for the run.
