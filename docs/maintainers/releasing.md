# Releasing yjson

本文只定义每次发布重复执行的流程与 gate。测试数量、commit、runner、时间和一次性结果必须写入对应 `release/<version>/evidence.md`，不在本页手工维护。

## Release identity

冻结候选版本后先记录：

- exact commit SHA 与 UTC 时间；
- `cjc`/`cjpm` 版本、SDK root 或 digest；
- runner identity、OS/libc、CPU architecture；
- release scripts revision；
- staged artifact 与 log checksum。

## Blocking gates

以下失败会阻止发布：

1. public API/ABI inventory 未评审或 machine-readable inventory 校验失败；
2. Pure Cangjie core、examples、macro consumer 任一失败；
3. Custom Native 或 yyjson package 不能由自身 staged source 独立构建；
4. warning gate、ASan、UBSan、LSan 或 differential fuzz 失败；
5. package input 缺失、出现未声明 Native dependency、license 缺失；
6. external consumer、版本配套、C ABI 或 yyjson symbol-isolation 失败；
7. documented example 失败或 Native ownership/lifetime 含糊；
8. source archive 包含 target、object、archive、shared library 或未声明 benchmark artifact；
9. qualified platform 上出现已确认的 release-blocking performance regression。

## Required jobs

| Job | Scope |
| --- | --- |
| `api-inventory` | public declarations、C ABI needles、exact package pairing |
| `core` | 无 C build hook 的 core tests |
| `examples` | public example build/run |
| `macro-consumer` | 外部式 `@JsonCodec` consumer |
| `custom-native` | package tests + external consumer，yyjson disabled |
| `yyjson-native` | offline vendored build、tests + consumer |
| `native-clang` / `native-gcc` | warnings 与 targeted C tests |
| `sanitizer` | ASan、UBSan、LSan |
| `fuzz-short` | PR 上 deterministic short differential fuzz |
| `fuzz-extended` | release 前 extended differential fuzz |
| `yyjson-symbol-isolation` | pinned dual-version co-link fixture |
| `package-rehearsal` | source-only manifests、staging、registry-style consumers |

仓库命令与 job mapping 见 [testing.md](testing.md)。SDK build 不属于普通 package release gate；需要验证 SDK 时按 SDK 仓库自身流程执行。

## Local and hosted evidence

本地 fresh-checkout simulation 与 hosted CI 是两个独立 gate，证据必须分别写：

```text
Local fresh-checkout simulation: PASS / FAIL / NOT RUN
Hosted CI execution: PASS / FAIL / NOT RUN
Release blocking policy: BLOCKING / NON-BLOCKING
```

本地 PASS 不能自动把 hosted execution 标为 PASS。是否允许 hosted NOT RUN 发布，必须在对应 release evidence 中给出明确 policy 与审批人。

## Platform statement

只对实际完成 SDK、build、tests、sanitizers 和 external consumer 的平台声明 supported/qualified。源码看起来可移植不等于已 qualification。

## Publish

在所有 blocking gate 与 evidence review 完成后，才执行 commit/tag/publish。发布动作、registry 返回值、artifact URL 和 checksum 追加到不可变 evidence；不要用后续 release 的结果覆写旧记录。
