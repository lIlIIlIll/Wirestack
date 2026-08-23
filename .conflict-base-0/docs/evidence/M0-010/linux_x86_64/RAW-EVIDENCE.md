# Raw evidence handling

The harness writes the full schema-versioned report to:

```text
build/gates/net05-large-buffer-profile.json
```

The report contains every measured read-size array, RSS sample, server send size,
process result and aggregate. It is intentionally not replaced by the compact
`manifest.json`.

For a reproducible native run:

```bash
source /mnt/data/cangjie-sdk/cangjie/envsetup.sh
scripts/with-host-gate-lock linux-native-gate -- \
  bash scripts/gate-net05-large-buffer-profile \
    --warmup 1 --repetitions 5

gzip -n -9 -c build/gates/net05-large-buffer-profile.json \
  > build/gates/net05-large-buffer-profile.json.gz
sha256sum \
  build/gates/net05-large-buffer-profile.json \
  build/gates/net05-large-buffer-profile.json.gz
```

A PR must not claim global GATE-NET-05 completion without attaching or otherwise
persisting that raw report, native Windows copied-byte evidence, and a future
`StdNetTransport` comparison.
