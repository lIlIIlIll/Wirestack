# Changelog

Wirestack has not published a stable release. Task status and evidence are
authoritative; this file summarizes milestones and does not replace them.

## Unreleased — 0.1.0 Linux candidate

Implemented and qualified on native Linux x86_64 glibc:

- bounded Transport SPI, `StdNetTransport`, resolver and Happy Eyeballs;
- build-time AWS-LC TLS 1.2/1.3 client/server with ALPN, SNI, trust, mTLS,
  external signer, session resumption and truncation evidence;
- HTTP/1.1 and HTTP/2 client/server, CONNECT, pooling, streaming, bounded
  retry/redirect and graceful shutdown;
- request, connection and HTTP/2 stream cancellation handles;
- one-hour H1/H2 SSE profiles, release fuzz and performance qualification;
- reproducible artifact, clean-consumer installation, SBOM, provider manifest
  and v0 API baseline.

Still required before a Linux stable release:

- M7-022's uninterrupted 24-hour soak;
- independent security review and finding closure;
- artifact/SBOM/manifest signing and security-update exercise;
- the final Linux release-candidate matrix.

The Windows, macOS, Android, iOS and HarmonyOS/OpenHarmony release matrix also
remains incomplete. See [Linux status](docs/planning/linux-status.md) and
[global status](docs/planning/status.md).
