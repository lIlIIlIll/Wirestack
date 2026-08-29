# TLS provider and native boundary

The Linux artifact selects AWS-LC at build time. The pinned provider is AWS-LC
5.5.0 at commit `991e67ff4cf04df4dd89e407f8b920c6936cb56a`. The default artifact
does not search for a system OpenSSL installation and has no runtime provider
fallback.

The C boundary is declared by
`native/tls/aws_lc/wirestack_tls_provider.h` and implemented by the adjacent C
source. Opaque native handles stay internal. The boundary uses explicit result
codes and bounded input/output lengths; C strings and native exception text are
not control flow. Provider identity and build fingerprints are diagnostic data,
not runtime selection inputs.

The M7-025 provider manifest, SBOM, bundle report, and build fingerprint describe
the pre-M7-032 artifact. They are intentionally marked stale in the evidence
index and must be regenerated for the final candidate after M7-029.

