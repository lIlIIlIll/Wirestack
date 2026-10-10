# Linux binary compatibility

Wirestack's current target is Linux x86_64 glibc. Source compatibility and binary compatibility are separate claims. The development archive is `NOT_QUALIFIED`; M12-002 evidence does not turn it into a production release.

## Capture and bind inputs

Run `tools/m12_002_binary.py` with the selected archive, each actual SDK root, a disk-backed private scratch directory, the SDK environment wrapper and an explicitly selected OpenSSL fixture library. The tool extracts the archive, scans every shipped static archive, records native manifests, builds an installed public consumer with the checkout hidden and executes each unchanged executable against every selected runtime.

```sh
python3 tools/m12_002_binary.py \
  --archive <selected-archive.tar.gz> \
  --sdk <stable-sdk> --sdk <candidate-sdk> \
  --scratch <disk-backed-private-scratch> \
  --wrapper <sdk-environment-wrapper> \
  --openssl-library /usr/lib/libssl.so.3 \
  --openssl-crypto-library /usr/lib/libcrypto.so.3
```

`--consumer <installed-executable>` adds ELF scans of independently built installed applications. `--verify` checks the selected archive, production sources, fixture sources, capture tool, native tool binaries, SDK compiler/runtime libraries and retained command logs against the report's typed digest bindings. Any changed input requires a fresh capture. A compiler version string alone is not a binding. SDK source qualification snapshots do not qualify replacement compiler or runtime bits.

The report and normalized command outputs are under `docs/evidence/M12-002/binary/`. Static archive members have no `DT_NEEDED` section. Their unresolved C/C++ symbols become runtime requirements only after final linking; inspect the produced executables and the selected runtime libraries as well.

## ISA and libc limits

The capture records ELF architecture, dynamic dependencies, SONAME, RPATH/RUNPATH, absolute loader-path hazards, GNU x86 property notes, GLIBC/GLIBCXX/CXXABI versions, public symbol inventories and raw instruction counts. Provider build manifests and fixture compile commands carry the compiler and flags. A shipped `-march=native` or `-mcpu=native` flag fails capture.

The archive's recorded compiler version and flags do not recover the original compiler's executable bytes. Current compiler snapshots are not retrospective provenance. Likewise, an SDK version string does not disclose its upstream build flags; without an input-bound SDK build manifest those flags remain unknown. Neither input snapshots nor scans qualify a changed SDK, provider or archive.

AES, PCLMUL or AVX instructions inside an AWS-LC archive do not by themselves establish the minimum CPU. AWS-LC includes CPU-dispatched routines. Disassembly records presence, not whether a branch executes on a particular CPU. An absent GNU property note also does not prove baseline safety. Native CPU-model execution belongs to the deployment matrix, not to a text scan.

The highest imported GLIBC version is a necessary loader requirement, not sufficient proof of a supported oldest distribution. SDK runtime, kernel behavior, CA installation and the complete installed application still need actual execution on the declared minimum platform. Containers do not establish an old-kernel boundary.

## Independent native dependencies in one process

`examples/linux/m12_002/coexist/` uses the existing installed consumer's public HTTP server/client and explicit DER trust pattern. It adds a separate Cangjie static dependency that computes and verifies arithmetic through a native libc-backed fixture. The same executable runs a verified Wirestack TLS request and an independent OpenSSL TLS request against the Wirestack server, checks the response body and verifies both provider identities.

The external OpenSSL libraries are test-only. Their SSL and crypto paths and CA file must be explicitly supplied; Wirestack itself never guesses or loads system OpenSSL. The fixture uses `dlopen(selected_path, RTLD_NOW | RTLD_LOCAL | RTLD_DEEPBIND)` to isolate the OpenSSL symbol group while retaining the base libc/pthread implementation. It requires exact canonical SSL/crypto module ownership, different AWS-LC/OpenSSL entry addresses, and identical libc pthread lookup, thread-creation and key-allocation entries. Ordinary unisolated OpenSSL linking and interchangeable provider ABIs remain unsupported.

An earlier `dlmopen(LM_ID_NEWLM)` fixture crashed after independent TLS cleanup: AWS-LC's thread-local accessor received the invalid pointer `0xffffffffffffffff`. The exit139, loader trace and core are retained. Earlier isolated-namespace passes do not qualify that unsafe design. The failure is a coexistence/thread-storage boundary, not evidence of SDK ABI incompatibility. The current fixture instead keeps one libc/pthread key allocator and performs a fresh verified Wirestack TLS request after independent TLS cleanup.

The fixture verifies certificates and hostnames, exchanges real HTTP data over both TLS owners and checks the bodies. Compilation alone cannot pass. Direct OpenSSL-header symbols in the executable still resolve to AWS-LC, which provides concrete evidence for the unsupported ordinary unisolated boundary without passing one provider's handles into another. A nonzero cross-runtime exit requires diagnosis; a confirmed ABI loader incompatibility requires rebuilding against the selected SDK and passing source/install acceptance, not hiding the failure.

Each ABI execution records the dynamic loader's actual selected runtime initialization path. Merely selecting an SDK in a wrapper is not an ABI proof: a successful process must initialize that SDK's bound runtime library as well as complete the native/TLS assertions. This observation is specific to the tested executable and SDK bytes, not a general forward-compatibility promise.

No musl or Linux aarch64 support follows from this evidence. Those targets need supported SDKs, all native archives and native installation acceptance of their own.
