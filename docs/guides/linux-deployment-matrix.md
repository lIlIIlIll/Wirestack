# Select a verified Linux deployment profile

These profiles apply to the M11-004 development archive reused by M12-002. They do not qualify a formal release. The archive digest is `e430f08ff8596b1c43c1d1090b5c42d721abac3c03505656b2aea107ee7a079f`; at capture time all 164 production inputs matched that installed payload. The current revision has since moved 10 production inputs and three M11-004 consumer sources, so the committed reports are stale against this revision and cannot qualify it: the profile facts below describe the captured runs, not current acceptance. See the [M12-002 requalification status](../evidence/M12-002/requalification-status.json); recapture is required before citing these profiles as current evidence.

## Source compatibility

Use one selected SDK's compiler, CJPM, runtime, import metadata and standard libraries together. Recompile consumers after changing those SDK bits. A successful source build does not establish cross-SDK binary ABI compatibility.

| Profile | Compiler / matching CJPM | CPU and kernel | Effective glibc | Installed source and native behavior |
|---|---|---|---|---|
| Stable native host | 1.1.3 | Core i7-8700, Linux 7.2.7 | 2.44 | 47 checks, operational CLI/raw/gzip, SSE/WSS, service and six CA cases PASS |
| Qualified candidate native host | 1.3.0-alpha.06 | Core i7-8700, Linux 7.2.7 | 2.44 | Same 47 checks, operational commands and six CA cases PASS |
| Stable minimum-profile VM | 1.1.3 | KVM Westmere, Linux 5.15.0-198-generic | Explicitly selected 2.44 | Native installed-source rebuild and all 47 checks PASS |

The [source SDK guide](linux-source-sdk-compatibility.md) records selection, exact compiler/runtime fingerprints, hidden-checkout builds, whole-tree relocation, controlled CA installation and diagnostics. The candidate is the actually qualified compiler/runtime snapshot, not a promise for every nightly.

## Precompiled consumer compatibility

| Build / runtime | Native deployment profile | Same binary result | Evidence |
|---|---|---|---|
| Stable 1.1.3 / stable 1.1.3 | Host Linux 7.2.7, glibc 2.44 | Four consumer executables, 47 checks PASS after relocation | [Stable source profile](../evidence/M12-002/source-sdk/stable-native/report.json) |
| Candidate 1.3 / matching candidate runtime | Host Linux 7.2.7, glibc 2.44 | Four consumer executables, 47 checks PASS after relocation | [Candidate source profile](../evidence/M12-002/source-sdk/candidate-native/report.json) |
| Exact stable host executables / exact stable Linux SDK bits | KVM Westmere, kernel 5.15.0-198-generic, selected glibc 2.44 | Unchanged binary digests, 47 checks PASS | [Native minimum profile](../evidence/M12-002/platform/westmere-glibc244/report.json) |
| Exact stable host CLI / exact stable Linux SDK bits | Stock Jammy VM, same Westmere CPU/kernel, glibc 2.35 | UNSUPPORTED. CLI loader rejects required GLIBC_2.38, GLIBC_2.43 and GLIBC_2.44 symbols; other consumers were not attempted | [Retained failure](../evidence/M12-002/platform/westmere/report.json) |

The verified floor for these installed executables is glibc 2.44, a Westmere-class CPU and the exact tested 5.15.0-198-generic kernel profile. The guest advertises SSE3/SSSE3/SSE4.1/SSE4.2, CMPXCHG16B, POPCNT, AES and PCLMULQDQ, but no AVX/AVX2. This is an exercised CPU profile, not proof that every listed CPU flag is necessary or that all older processors work. The full CPUID mask is in the native report.

Only the listed combinations are supported by this evidence. No intermediate kernel/glibc combination or different SDK snapshot is inferred from a version range. Candidate SDK support on the weaker CPU/older kernel is not claimed. Binary ABI probes have their own scope in the [binary compatibility guide](linux-binary-compatibility.md); they never remove the default consumer-recompile requirement after an SDK change.

## Native VM evidence, not a container claim

The VM ran under QEMU 11.1.2 with KVM acceleration, two vCPUs and 3072 MiB. Its kernel was 5.15.0-198-generic while the host kernel was 7.2.7. Official Jammy cloud-image bytes were checked against the official HTTPS SHA256SUMS. The detached image signature was not verified.

Stock image glibc 2.35 failed to load the unchanged host consumer. The passing profile deliberately selected the fingerprinted Arch glibc 2.44 runtime inside a private guest mount namespace. Loader and runtime files were installed together as read-only bind mounts before any child process executed. It is not stock Ubuntu 22.04 support. Neither host files nor the guest root filesystem's glibc files were overwritten; after the namespace exited, guest `getconf GNU_LIBC_VERSION` still reported 2.35.

[Runtime provenance](../evidence/M12-002/platform/glibc244-runtime.json) binds the exact glibc package and fourteen runtime files. Preserve executable permissions when copying the dynamic loader. An initial test copy lost that permission, failed before acceptance, and was corrected without changing its bytes.

The VM received the installed package, independent consumer sources/binaries, selected Linux SDK and acceptance support tools. The development checkout was never transferred. Native GCC 11.4.0 and GNU ld 2.38 linked the rebuilt consumers; historical shipped native archives retain their recorded Clang 15.0.7 build settings. Recompiling a consumer does not rebuild or retroactively qualify those archives.

## Dependencies and trust

The installed TLS provider, resolver and HTTP filesystem helper are pinned static archives. Optional gzip is pure Cangjie and adds no zlib or other native compression dependency. The four default consumers need `libboundscheck.so`, `libcangjie-runtime.so`, `libc.so.6` and `libm.so.6`. Supply the matching SDK runtime deliberately. Default Wirestack consumers do not need a system OpenSSL installation.

Explicit DER and system CA paths and failure diagnostics are recorded in the source SDK guide. Tests provision controlled system trust only inside private namespaces. Missing trust is a failure, not an automatic provider or CA fallback.

Independent TLS coexistence is a separate explicit fixture contract. Do not treat different SSL function addresses as sufficient proof of safe shared-thread state. Use only the isolation mechanism and lifecycle actually verified in the binary compatibility report; ordinary unisolated OpenSSL coexistence is not promised.

## Repeat or invalidate a profile

On an owned native KVM VM with the recorded inputs, run the real acceptance tool:

```bash
python3 tools/m12_002_platform.py \
  --sdk-root "$SDK_ROOT" --tree "$INSTALLED_TREE" --fixtures "$FIXTURES" \
  --stable-report "$STABLE_REPORT" --host-kernel "$HOST_KERNEL" \
  --image-provenance "$PROVENANCE" --output "$OUTPUT"
```

`INSTALLED_TREE` is the relocated tree produced by a stable source capture. `FIXTURES` contains its certificate DER, key DER and untrusted DER files. Use a new output directory. `HOST_KERNEL` is the kernel of the qualifying source host, and the verifier requires it to equal the kernel recorded by the stable source report; it exists only to prove the guest kernel is a different kernel than the host that built the payload. The tool compares the original executable digests before execution, validates the installed payload and Linux SDK closure, runs all 47 checks, creates a separate installed-tree copy, rebuilds the consumers and runs all 47 checks again. It preserves compiler and command diagnostics on failure.

For the controlled glibc profile, run `tools/m12_002_glibc_namespace.py` through `sudo unshare --mount --propagation private` inside that owned VM. Provide the selected runtime directory and its provenance, an unprivileged UID/GID and the acceptance command after `--`. The helper rejects shared mounts, host/non-KVM use, undeclared runtime files and changed runtime digests. The namespace disappears when the command exits.

Set `WIRESTACK_STABLE_SDK_ROOT` and `WIRESTACK_CANDIDATE_SDK_ROOT` to the exact qualified SDK installations, and `WIRESTACK_BINARY_CAPTURE_ROOT` to the retained successful binary capture directory, before running `python3 tools/m12_002_deployment.py verify`. The verifier rechecks the scanned binaries and their native tool/library closure; retaining only JSON reports is insufficient. The collector also requires each retained profile's production sources to be exactly the current `release.production_sources` set and its recorded compiler digest to be the compiler on this host, so a profile cannot qualify by dropping a source or by being collected with a different compiler. Archive, production source, provider/native archive, SDK, native compiler, task source or evidence drift invalidates the snapshot. Rebuild and rerun the affected profiles and the existing release gates. An uncommitted task snapshot cannot qualify another candidate or replace a committed release seal.

Linux aarch64 requires a formal SDK, native runner, every native dependency and installed-consumer acceptance before starting a separate profile. musl remains deferred. Neither platform, Windows nor macOS is an M12-002 gate or support claim.
