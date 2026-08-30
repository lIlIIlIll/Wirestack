# M3-030 evidence

## Status

COMPLETE

The final six-command M3-030 task gate passes. The refreshed M7-029 independent
review is bound to security-package digest
`9d4c4676cd52883aa002e20946b474ac2777d7fcee2bcfe9c232436c44aeaf82`,
closes both native ABI High findings, and has no unresolved Critical or High
finding. The M2-003 resolver contract fixture and native bound gate also pass.

## Scope

M3-030 separates provider-neutral TLS and HTTP code from the selected native TLS
implementation. The only production combination implemented and accepted by this
task is `linux-x86_64-glibc + aws-lc`.

The task does not implement or claim Windows, Apple, Android, HarmonyOS, Linux
musl, or a pure Cangjie TLS provider.

## Evidence

- `platform-provider-matrix.json`: exact build-time selection with no fallback.
- `native-abi-report.json`: provider ABI v1 symbol and schema-v2 signature
  validation for 56 C functions, including Cangjie FFI and compiled header
  probes.
- `architecture-guard.json`: zero concrete-provider boundary violations.
- `test-provider-results.json`: factory substitution, mismatch rejection, and
  retained lifetime; 3 passed, 0 failed.
- `linux-aws-lc-results.json`: pinned AWS-LC 5.5.0 selection and capabilities.
- `clean-consumer.json`: public-API-only build and HTTPS loopback.
- `release-validation.json`: reproducible installed Linux artifact.
- `sbom-validation.json`: provider-bound SBOM and build fingerprint.

The complete non-performance Cangjie run reported 592 total, 569 passed, 23
explicitly skipped, and zero failures or errors. The skipped cases are not
recorded as PASS. The final compatibility entry point `scripts/check` also
returned exit 0 after the task and review evidence were current.

## Evidence boundary

The task did not run the one-hour SSE profile, the 86,400-second release soak,
or non-Linux gates. Those commands are excluded from the task manifest. This
task makes no Windows, Apple, HarmonyOS, Android, musl, or pure-Cangjie provider
support claim.
