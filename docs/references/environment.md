# Verified environment and external inputs

This page summarizes the current repository environment. The dated records in
this directory retain command output, hashes and source provenance; this page is
navigation, not a replacement for those records.

## Qualified local profile

| Input | Current verified value | Authority |
|---|---|---|
| Cangjie compiler | `1.1.0-alpha.20260817040003` (`cjnative`) | [SDK inspection](cangjie-sdk-1.1.0-alpha.20260817040003.md) |
| Target | `x86_64-unknown-linux-gnu` | [SDK pin](sdk-20260817.md) |
| CJPM | `1.1.3` | [SDK inspection](cangjie-sdk-1.1.0-alpha.20260817040003.md) |
| Product platform | native Linux x86_64 glibc | [ADR-0004](../architecture/adr/0004-linux-glibc-support.md) |
| TLS provider | AWS-LC 5.5.0, commit `991e67ff4cf04df4dd89e407f8b920c6936cb56a` | [ADR-0003](../architecture/adr/0003-linux-tls-provider.md) |
| Public package version | `0.1.0` | [`cjpm.toml`](../../cjpm.toml) |

Linux musl is not supported by the current Cangjie SDK. The provider-only musl
PoC is portability evidence, not a Wirestack product claim. P1-011 begins only
after the SDK supplies a supported target, runtime, standard library and build
instructions.

## Repository boundary

Wirestack does not vendor or own the Cangjie SDK, runtime, std, stdx, platform
trust/key stores, or provider source checkout. These are external inputs and
read-only references from a Wirestack task. Actual upstream changes belong in
their own repositories and are not Wirestack release dependencies.

## Reproduce the environment check

```bash
/home/elliot/.codex/scripts/codex_cangjie_env scripts/repo-doctor --json
```

The doctor reports required missing capabilities as `BLOCKED`, optional or
workspace limitations as `DEGRADED`, and a satisfied environment as `READY`.
It does not treat missing tools or unsupported platforms as a pass.

## Other platforms

Windows, macOS, Android, iOS and HarmonyOS/OpenHarmony remain product targets,
but their complete native evidence is not available in this Linux checkout.
Cross-compilation does not close those status entries. Consult
[global status](../planning/status.md) before making a platform claim.
