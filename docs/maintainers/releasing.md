# Releasing yjson

本文只定义每次发布重复执行的流程与 gate。测试数量、commit、runner、时间和一次性结果必须写入对应 `release/<version>/evidence.md`，不在本页手工维护。

## Release identity

候选 evidence 必须绑定 exact commit、工具链身份、gate 结果与 artifact checksum。临时目录、
开发机路径和逐条执行过程不属于发布说明。

## Blocking gates

以下失败会阻止发布：

1. public API/ABI inventory 未评审或 machine-readable inventory 校验失败；
2. Pure Cangjie core、examples、macro consumer 任一失败；
3. 固定 revision 的 JSON Schema required、JSONPath CTS 或 JSON Patch conformance gate 失败；
4. yjson、stdx.json、cjfast_json 同批次性能表缺少任一共同 workload 或任一库；
5. Custom Native 或 yyjson package 不能由自身 staged source 独立构建；
6. warning gate、ASan、UBSan、LSan 或 differential fuzz 失败；
7. package input 缺失、出现未声明 Native dependency、license 缺失；
8. external consumer、版本配套、C ABI 或 yyjson symbol-isolation 失败；
9. documented example 失败或 Native ownership/lifetime 含糊；
10. source archive 包含 target、object、archive、shared library 或未声明 benchmark artifact；
11. qualified platform 上出现已确认的 release-blocking performance regression。

高 CV 本身不阻止发布，也不得删除对应行；该行必须标为 `noisy`，是否构成性能回归由
release owner 根据配对方向、历史基线和 workload 重要性单独判定。

## Required jobs

| Job | Scope |
| --- | --- |
| `api-inventory` | public declarations、C ABI needles、exact package pairing |
| `core` | 无 C build hook 的 core tests |
| `standards-conformance` | pinned Schema required、JSONPath CTS 与 JSON Patch public-API consumer |
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

job mapping 见 [testing.md](testing.md)。SDK build 不属于普通 package release gate。

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
