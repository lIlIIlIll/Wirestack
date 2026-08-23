# Linux x86_64 evidence index

- [`summary.md`](summary.md): human-readable conclusions.
- [`manifest.json`](manifest.json): compact machine-readable status and case inventory.
- [`formal-run.status`](formal-run.status): line-oriented task/gate state.
- [`sdk.sha256`](sdk.sha256): supplied SDK archive identity.
- [`RAW-EVIDENCE.md`](RAW-EVIDENCE.md): exact command and raw-report handling.

The formal run executed both 1 MiB and 100 MiB cases with one warmup and five
measured samples each. Exact byte and payload-pattern verification passed, and
application-visible reads larger than 4096 bytes were observed with a 65536-byte
destination buffer.
