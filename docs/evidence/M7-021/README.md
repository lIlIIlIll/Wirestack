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
| Size | 2,474,219 bytes |
| SHA-256 | `55aec28b201b3481e85b647eee0f180f3f0ca0677b098f866b385a8e6a9bba55` |
| Payload SHA-256 | `44a2127078e1f0c57c5406caff995b72892bf78e60ada57ded972df7b1d7bfbc` |
| Production Cangjie files | 87 |
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
HTTP_VERSION=2
transportBackend=std-net
runtimeIoBackend=cjnative
tlsProvider=aws-lc
tlsProviderVersion=5.5.0
externalOpenSslDependency=false
buildFingerprint=bb632e197f6a0b097ddc378e2fa8889a59ecfc0fc7b15bfa2c08a4f4b9901038
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
found no `libssl` or `libcrypto`. The artifact payload and the installed ELF
also contain no `libssl.so` or `libcrypto.so` loader string.

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
