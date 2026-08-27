# Cangjie Linux musl target availability, 2026-08-27

This record defines why ADR-0004 defers Linux musl. The project owner confirmed
on 2026-08-27 that the current Cangjie SDK does not support musl. This record
also retains the local toolchain evidence.

## Local SDK

The active compiler reports:

```text
Cangjie Compiler: 1.1.0-alpha.20260817040003 (cjnative)
Target: x86_64-unknown-linux-gnu
```

`/home/elliot/cangjie_sdk/daily/cangjie` contains
`modules/linux_x86_64_cjnative`, `lib/linux_x86_64_cjnative`, and
`runtime/lib/linux_x86_64_cjnative`. No path in that SDK contains a musl target
module or runtime.

## Server runner

`ssh Server` reports Linux x86_64 with glibc. Neither `cjc` nor `cjpm` is
installed. Podman is installed, but a container cannot supply the missing
Cangjie musl standard library and runtime by itself.

## Published compiler documentation

The [Cangjie 1.0 compiler options](https://docs.cangjie-lang.cn/en/docs/1.0.0/user_manual/source_en/Appendix/compile_options.html#--target-value)
define the target triple's environment component and use `gnu` and `musl` as
examples. The documented Linux-host cross-target table lists Windows GNU. It
does not list Linux musl. The same page requires a matching target Cangjie SDK
and cross toolchain before `--target` can produce a runnable target binary.

The [Cangjie SDK integration build guide](https://gitcode.com/Cangjie/cangjie_build/blob/main/README.md)
publishes native Linux and cross-build guides for Windows, Android, and OHOS.
It does not publish a Linux musl SDK build or validation path.

These pages were checked on 2026-08-27. They document Cangjie 1.0 and the
current public build guide. The active daily compiler is newer, so the local SDK
inventory remains the decisive evidence for this workspace.

## Project consequence

The glibc gate can run now. The musl gate cannot compile or execute the public
`wirestack.http.SystemResolver`. ADR-0004 therefore limits the current Linux
release to glibc and moves musl adoption to P1-011. A C-only Alpine smoke remains
provider or bridge evidence, not Wirestack platform support.
