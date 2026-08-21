# yjson 2.0.0 RC1 evidence snapshot

本页从原 `docs/release-checklist.md` 中拆出。它保留当时记录的结果，但还不是完整、可独立审计的 release artifact：原记录没有固定 commit SHA、UTC 时间、SDK digest、runner identity 与每个 log checksum。正式发布前必须补齐这些字段并重新运行 blocking gates。

## Identity

| Field | Value |
| --- | --- |
| Commit SHA | NOT RECORDED |
| UTC time | NOT RECORDED |
| SDK digest | NOT RECORDED |
| Runner identity | self-hosted Linux x86_64, exact identity NOT RECORDED |
| Artifact/log checksums | NOT RECORDED |

## Recorded gate state

- Source-only release manifest：PASS，记录为 103 files，并排除 `target/`、object、archive、shared library、performance corpora 与 results。
- Core suite：PASS，原记录为 498 tests。
- Examples 与 external core/macro/Custom Native/yyjson consumers：PASS。
- Custom Native package：PASS，原记录为 9 tests。
- yyjson Direct package：PASS，原记录为 6 tests。
- Clang/GCC warning builds、targeted scanner/Native/yyjson tests：PASS。
- ASan、UBSan、LSan：PASS。
- Deterministic differential fuzz：PASS，原记录为 50,000 cases。
- Registry-style staging/rehearsal：PASS；五个 artifact 完成检查，四类 consumer build/run 通过。`cjpm` 1.1.3 没有 local-registry 或 publish dry-run，因此没有真实 registry publish。
- yyjson vendoring 与 symbol isolation：PASS；记录为 vendored 0.12.0，最终 shared library 导出零个 upstream `yyjson_*` implementation symbol，pinned 0.11.1 dual-version fixture 两种 load order 通过。
- Commit/tag/publish：NOT RUN。

## CI state

```text
Local fresh-checkout simulation: PASS
Hosted GitCode execution: NOT RUN
Release blocking policy: NOT RECORDED
```

原 hardening round 未授权 push，因此 hosted execution 没有发生。这不能写成合并的 “CI PASS”；正式 release review 必须明确它是 blocking 还是经审批 non-blocking。

## Environment notes retained from the snapshot

- Linux x86_64 当时被标记为 qualified；AArch64 仅被认为 source-portable，未 qualification；musl 未测试。
- Release checks 会拒绝混合 Cangjie SDK 环境；`cjc`、`CANGJIE_HOME`、`CANGJIE_SDK_ROOT` 与 `CJ_SDK_LIBPATH` 必须来自同一 SDK。
- yyjson 使用未修改的 vendored 0.12.0 source，并包含 MIT license。

稳定流程与当前 blocking policy 定义见 [`docs/maintainers/releasing.md`](../../docs/maintainers/releasing.md)。
