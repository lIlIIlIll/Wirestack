# M7-021 Linux release artifact qualification

Status: **COMPLETE**

Decision: **PASS**

M7-021 produced and installed the native Linux x86_64 glibc release artifact.
The clean consumer ran an HTTPS client and server through the public
`wirestack.http` API. It also queried `TlsRuntime.info()`.

## Artifact

| Field | Result |
|---|---|
| Name | `wirestack-0.1.0-linux-x86_64-glibc.tar.gz` |
| Size | 2,499,451 bytes |
| SHA-256 | `c0988f62eb657c465a928825573e41e2eb2675241240312bc2228482cbafc9ee` |
| Payload SHA-256 | `45ca196866697b568d33894bf3673aaec63fee01ee661bc5fc8319cd27c09e22` |
| Production Cangjie files | 108 |
| Reproducibility | Two builds were byte-identical |

The artifact contains production Cangjie source, CJPM metadata, the pinned
AWS-LC archive, and the bounded resolver archive. It excludes tests, build
caches, and the Android, Apple, Harmony, and Windows placeholder packages.
Generated tar and gzip metadata use fixed ownership, permissions, ordering, and
timestamps.

The local artifact remains under `dist/m7-021/`, which Git ignores. Run the
qualification command to regenerate the file from the recorded inputs.

## Installation smoke

The gate extracts the artifact into a new temporary directory. It creates an
independent executable CJPM project whose only project dependency is the
installed artifact root. The consumer fixture imports public APIs only.

The native smoke returned:

```text
HTTPS_CLIENT_SERVER=PASS
PUBLIC_TLS_FACADE=PASS
HTTP_VERSION=2
transportBackend=std-net
runtimeIoBackend=cjnative
tlsProvider=aws-lc
tlsProviderVersion=5.5.0
externalOpenSslDependency=false
buildFingerprint=030369238045d5710c42d86f16aa7d520573e2a6ef50e4246d5d769bbf66467d
```

The `buildFingerprint` line is the provider build fingerprint returned by
`TlsRuntime.info()`. The artifact payload has its own SHA-256 value in the table
above. M7-025 owns the final release build fingerprint and SBOM bundle.

## Dependency scan

`readelf -d` found these direct dependencies in the installed consumer:

- `libboundscheck.so`
- `libc.so.6`
- `libcangjie-runtime.so`
- `libm.so.6`

`ldd` resolved the transitive Cangjie runtime and system C/C++ libraries. It
resolved the Cangjie libraries from the fixed 20260817 SDK and found no
`libssl` or `libcrypto`. The artifact payload and the installed ELF also
contain no `libssl.so` or `libcrypto.so` loader string.

The machine-readable report is
[`linux_x86_64/qualification.json`](linux_x86_64/qualification.json). Its test
binds the PASS decision to the current source tree, build script, smoke fixture,
manifest, and backlog entry.

## Repeat the gate

Prepare the normal Cangjie environment, then run:

```shell
scripts/qualify-m7-021-linux-release --offline
```

The first sandboxed smoke attempt failed because the restricted test process
could not create a local socket. The same generated artifact passed on the
native host. Product code was not changed to work around the sandbox.

M7-021 did not build or modify the Cangjie SDK, runtime, or standard library.
Those repositories are not release dependencies.

## Evidence boundary

This task does not claim an SBOM, signing, the final 24-hour soak, or a
non-Linux release. M7-025 owns the SBOM and fingerprint bundle. M7-030 owns
signing. M7-022 owns the final artifact soak.
