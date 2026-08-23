# M0-001 Evidence

## Result

```text
COMPLETE
```

M0-001 is complete as an inventory task. It does not claim that any runtime
network gate or platform support requirement has passed.

## Acceptance checklist

| Acceptance item | Result | Evidence |
|---|---|---|
| Current packages and public API inventoried | PASS | `docs/architecture/current-network-stack-inventory.md` §§3–4 |
| OpenSSL/native dependencies inventoried | PASS | inventory §5 and pinned stdx manifest/CMake sources |
| Build and distribution paths inventoried | PASS | inventory §6 |
| Existing test/evidence situation inventoried | PASS | inventory §7 |
| Platform differences listed | PASS | inventory §8 |
| Delete/reuse/isolate/reference decisions recorded | PASS | inventory §9 |
| SDK identity and tool versions pinned | PASS | `docs/references/cangjie-sdk-1.1.0-alpha.20260817040003.md` |
| Six-platform runtime semantics verified | NOT RUN | Belongs to M0-004 through M0-014 and native platform tasks |

## Local command results

```text
sha256sum cangjie_sdk.tar.gz
bc2ed8a34b9b6846a5445d3eba0ac66b146730a005d3df56d45a2b119416f40d

cjc -v
Cangjie Compiler: 1.1.0-alpha.20260817040003 (cjnative)
Target: x86_64-unknown-linux-gnu

cjpm -v
Cangjie Project Manager: 1.1.3
```

A static-library and nested-package probe completed with:

```text
cjpm check success
cjpm build success
```

The first probe intentionally exposed that CJPM skips descendants of an empty
parent source directory. Adding `src/internal/package.cj` made all intended
`wirestack.internal.*` packages discoverable. This is durable input to M0-002.

## Source snapshots

```text
cangjielanguage/cangjie_stdx
9581a10b9b81b259155c26701afe1478d4892f32

cangjielanguage/cangjie_runtime
335fc487d782a566e3240004522ba55b38989369
```

These commits are inspection pins, not a claim of exact binary reproducibility
for the user-supplied SDK.

## Important negative evidence

- No `stdx.net.tls` or `stdx.net.http` artifact is present in the supplied SDK.
- Only Linux x86_64 was executed.
- Windows binaries were observed but not run.
- No macOS, Android, iOS or HarmonyOS/OHOS native execution environment was supplied.
- No GATE-NET task was executed or marked passed.
- No upstream `std.net`/runtime task was unlocked.
