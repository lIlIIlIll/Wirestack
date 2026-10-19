# M10-002 close-admission review regression

SDK: Cangjie STS 1.1.3. Target: `x86_64-unknown-linux-gnu`.

The command ran after sourcing `$HOME/cangjie_sdk/sts1.1.3/envsetup.sh`; `TMPDIR`, `TMP`, and `TEMP` pointed to a disk-backed task-owned directory (normalized as `<task-tmp>`).

```sh
cjpm test src/http --filter=HttpClientExtensionsTest.closingClientTerminatesAdmissionWaiterAndPreservesHeldRequestLease --no-color --no-progress
```

Exit: 0. `TOTAL: 159`; `PASSED: 1`; `SKIPPED: 158`; `ERROR: 0`; `FAILED: 0`.
