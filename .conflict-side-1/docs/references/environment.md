# External Environment and Source References

This document records exact external inputs used by Wirestack tasks. It is not a
dependency lockfile.

## Repository boundary

Wirestack does not vendor or own:

- Cangjie SDK/toolchain;
- `cangjie_stdx`;
- `std.net`;
- Cangjie runtime/CJThread socket AIO source;
- TLS provider candidate source repositories;
- platform trust/key stores.

Actual source changes to `std.net` or runtime belong in their upstream
repositories.

## Environment record

The repository bootstrap intentionally does **not** claim a Cangjie toolchain
version or physical `cjpm` package layout, because no runtime/toolchain evidence
has been captured in this repository yet.

M0-001 and M0-002 must record at minimum:

| Input | Version / commit | Location / source | Verified by |
|---|---|---|---|
| Cangjie compiler | TBD | TBD | M0-001 |
| cjpm | TBD | TBD | M0-001 |
| Cangjie SDK | TBD | TBD | M0-001 |
| `cangjie_stdx` legacy baseline | TBD | TBD | M0-001 |
| `std.net` source/runtime | TBD | TBD | M0-001 |
| Windows target | TBD | TBD | M0-017 |
| Linux glibc/musl targets | TBD | TBD | M0-017 |
| macOS target | TBD | TBD | M0-017 |
| Android target | TBD | TBD | M0-017 |
| iOS target | TBD | TBD | M0-017 |
| HarmonyOS/OHOS target | TBD | TBD | M0-017 |
| selected TLS provider | TBD | TBD | M0-020 |
