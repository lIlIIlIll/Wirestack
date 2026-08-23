# Raw evidence handling

The harness writes its full schema-versioned report to:

```text
build/gates/net06-leak-soak.json
```

The report contains every process result, server counter, timestamped RSS/FD
sample and aggregate, plus the complete deferred-requirement list.

Reproduce the bounded native run:

```bash
source /mnt/data/cangjie-sdk/cangjie/envsetup.sh
scripts/with-host-gate-lock linux-native-gate -- \
  bash scripts/gate-net06-leak-soak

gzip -n -9 -c build/gates/net06-leak-soak.json \
  > build/gates/net06-leak-soak.json.gz
sha256sum build/gates/net06-leak-soak.json \
  build/gates/net06-leak-soak.json.gz
```

The bounded report must not be substituted for the unexecuted 100,000-iteration,
TLS, 24-hour or native-platform evidence.
