# Reconstructed repaired checker input bundle

This directory is a reconstructed, durable copy of the frozen checker inputs for the
repaired-source paired performance follow-up. It was reconstructed after the review
found that `checker/check.py` still resolved the pre-repair `server-performance/input`
snapshot, whose `examples/linux/m12_001/http.cj` text digest is `9b1ad9…`, while
`../input-manifest.json` requires the repaired `1c6a49…` source.

Reconstruction method (no measurement or benchmark was rerun):

- `repo/` is a copy of the previously committed `docs/evidence/M12-004/server-performance/input/repo`
  snapshot, except `repo/examples/linux/m12_001/http.cj` was replaced by the repository
  file of the same repaired source. Every entry in `../input-manifest.json` `source_inputs`
  now matches this copy (typed `text-utf8-lf-v1` digests); the other nine source inputs were
  already unchanged between the pre-repair and repaired captures.
- `inputs.json` is the checked-in repaired capture input manifest (`../input-manifest.json`),
  matching the capture report's `input_manifest` field.
- `sdk-oracle.json` and `glibc244/provenance.json` are copied from the previously committed
  input bundle; their digests match the repaired manifest.
- The two paired measurement archives (`baseline.tar.gz`, `candidate.tar.gz`) and the private
  frozen glibc 2.44 runtime files under `glibc244/` are deliberately not vendored. They are
  external inputs: without them the checker reports a truthful `BLOCKED` result, and full
  validation requires supplying them at these paths.

The reconstruction is explicit so the published checker never silently validates a capture
against the wrong source snapshot.
