# Known limitations

- The qualified platform is Linux x86_64 with glibc. The current Cangjie SDK
  does not provide the required musl target, so Wirestack makes no musl claim.
- M7-028 prepares review inputs. It does not constitute independent review;
  M7-029 records findings and closure.
- Artifact, installation, performance, SBOM, and audit evidence created before
  M7-032 is stale for the final candidate. It remains visible for provenance.
- M7-026 is a historical API inventory, not a compatibility target or gate.
- The one-hour SSE profile and 86,400-second combined release soak are not run
  by this task. The final soak runs once on the frozen release candidate.
- An existing scheduling-sensitive H2 SSE producer-close observation passed on
  focused rerun and serial full-suite execution, but M7-032 did not claim the
  default-parallel race was resolved.
- No non-Linux platform evidence is claimed.

