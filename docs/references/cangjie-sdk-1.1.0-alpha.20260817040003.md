# Cangjie SDK Inspection Record

## Identity

| Field | Value |
|---|---|
| Input archive | `cangjie_sdk.tar.gz` supplied in the project conversation |
| Archive size | 436,409,840 bytes |
| SHA-256 | `bc2ed8a34b9b6846a5445d3eba0ac66b146730a005d3df56d45a2b119416f40d` |
| Compiler | `Cangjie Compiler: 1.1.0-alpha.20260817040003 (cjnative)` |
| Host target | `x86_64-unknown-linux-gnu` |
| CJPM | `Cangjie Project Manager: 1.1.3` |
| Inspection date | 2026-08-22 |

The archive is an input toolchain, not a repository dependency. It must not be
committed or vendored into Wirestack.

## Archive structure

Top-level directories and files observed after extraction:

```text
LICENSE
Open_Source_Software_Notice.docx
bin/
envsetup.sh
include/
lib/
modules/
runtime/
third_party/
tools/
```

The extracted tree occupies approximately 1.3 GiB in the inspection workspace.

## Network-related artifacts

The archive contains the core `std.net` module and runtime artifacts for Linux
x86_64 and Windows x86_64:

```text
lib/linux_x86_64_cjnative/libcangjie-std-net.a
lib/linux_x86_64_cjnative/libcangjie-std-netFFI.a
lib/windows_x86_64_cjnative/libcangjie-std-net.a
lib/windows_x86_64_cjnative/libcangjie-std-netFFI.a
modules/linux_x86_64_cjnative/std/libstd.net.bc
modules/linux_x86_64_cjnative/std/std.net.cjo
modules/windows_x86_64_cjnative/std/std.net.cjo
runtime/lib/linux_x86_64_cjnative/libcangjie-std-net.so
runtime/lib/windows_x86_64_cjnative/libcangjie-std-net.dll
```

No `stdx.net.tls` or `stdx.net.http` module, source tree, test corpus, or FFI
archive was found in the supplied SDK. Existing TLS/HTTP behavior therefore had
to be inspected from the separately pinned `cangjie_stdx` source snapshot.

## Verified CJPM behavior

`cjpm init --name wirestack --type=static` generated a valid static-library
manifest with `cjc-version = "1.1.0"` and `output-type = "static"`.

A multi-package probe established an important source-layout rule for this CJPM
version: a directory that has no `.cj` file is not treated as a package and its
subdirectories are not scanned. Therefore `src/internal/package.cj` is required
before packages under `src/internal/*` can participate in the build.

After adding the parent package, the probe successfully checked and built these
packages:

```text
wirestack
wirestack.http
wirestack.tls
wirestack.internal
wirestack.internal.common
wirestack.internal.transport
wirestack.internal.transport_stdnet
wirestack.internal.resolver
wirestack.internal.connector
wirestack.internal.tls_engine
wirestack.internal.trust
wirestack.internal.identity
wirestack.internal.http1
wirestack.internal.http2
```

The build emitted independent `.cjo` and static archive outputs for each package.
This evidence is used by M0-002; it does not itself freeze public API declarations.

## Commands executed

```bash
sha256sum /mnt/data/cangjie_sdk.tar.gz
source <extracted-sdk>/envsetup.sh
cjc -v
cjpm -v
find <extracted-sdk> -name 'std.net.cjo' -o -name 'libstd.net.bc' \
  -o -name 'libcangjie-std-net.so' -o -name 'libcangjie-std-net.dll' \
  -o -name 'libcangjie-std-net.a' -o -name 'libcangjie-std-netFFI.a'
cjpm init --name wirestack --type=static
cjpm check
cjpm build
```

All listed local commands exited with status 0. The only build diagnostic in the
complete multi-package probe was an expected unused-import warning in the
`transport_stdnet` marker package.

## Scope limitations

- Only Linux x86_64 execution was available in this inspection container.
- Windows artifacts were inventoried but not executed.
- The archive contains no macOS, Android, iOS, or HarmonyOS/OHOS target artifacts.
- Presence of a module or runtime file is not proof that Wirestack's cancellation,
  EOF, performance, or lifecycle requirements are satisfied.
- Six-platform claims remain blocked on the corresponding native runners or devices
  and the M0 gate suite.
