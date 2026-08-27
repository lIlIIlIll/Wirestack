# Linux x86_64 evidence index

- [`result.json`](result.json): complete schema-v2 raw report.
- [`summary.md`](summary.md): measured conclusion.
- [`manifest.json`](manifest.json): compact machine-readable inventory.
- [`formal-run.status`](formal-run.status): line-oriented gate state.
- [`result.sha256`](result.sha256): raw report identity.
- [`sdk.sha256`](sdk.sha256): supplied SDK archive identity.
- [`RAW-EVIDENCE.md`](RAW-EVIDENCE.md): command and evidence boundaries.

The formal run covers 1 KiB, 16 KiB, 64 KiB, 1 MiB and 100 MiB with one
warmup and eleven measured samples per implementation. It retains native
allocation events, syscall receive bytes and adapter staging-copy bytes.
