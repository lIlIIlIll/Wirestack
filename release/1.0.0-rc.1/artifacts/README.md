# 1.0.0-rc.1 local evidence artifacts

This directory contains the immutable inputs and outputs retained from the local candidate
validation:

- `environment.json`: runner, SDK and compiler identity;
- `manifest.json`: candidate commit, gate result and external fixture identity;
- `logs/`: successful transcripts plus failed attempts retained for auditability;
- `packages/`: five `.cjp` files produced by the registry-style rehearsal;
- `checksums.txt`: SHA-256 for the files above, excluding the checksum file itself.

The artifacts prove the recorded local runs only. They do not represent hosted CI, an annotated
tag, or a registry publication.
