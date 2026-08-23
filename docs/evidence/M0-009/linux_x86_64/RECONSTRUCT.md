# Raw evidence reconstruction

The exact gzip stream is committed as UTF-8 base64 text because the repository
write path used for this task accepts text content. Reconstruct and verify it:

```bash
base64 -d result.json.gz.base64 > result.json.gz
sha256sum -c result.json.gz.sha256
gzip -dc result.json.gz > result.json
sha256sum -c result.sha256
sha256sum -c result.json.gz.base64.sha256
```

The encoded file is not itself the JSON result. The SHA-256 files pin the
encoded text, reconstructed gzip stream, and decompressed JSON independently.
