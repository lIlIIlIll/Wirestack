# yjson 2.0.0 release evidence

本页记录 2.0.0 候选源码的可审计验收状态。所有 PASS 均绑定候选提交、source-only
allowlist、完整 transcript、机器可读摘要或 checksum；证据目录自身不在候选源码
allowlist 中，因此不会改变已验证源码。

## Identity

| Field | Value |
| --- | --- |
| Planned release identity | `2.0.0` |
| Candidate source commit | `2d02b82ceb96e4ce170c09913a279f0963f5a212` |
| Evidence generated | `2026-08-27T04:44:21Z` |
| Package manifest version | `2.0.0`（九个 package，尚未发布） |
| Qualification runner | `Arch`, Linux x86_64, glibc 2.44 |
| Qualification SDK | Cangjie `1.1.0-alpha.20260817040003`, cjpm `1.1.3` |
| Performance runner | `ubuntu2223131`, Linux x86_64, glibc 2.35, CPU 8 pinned |
| General performance SDK | Cangjie `1.1.0-alpha.20260803040049`, cjpm `1.1.3`, stdx `0.0.3` |
| Native performance SDK | Cangjie `1.1.0-alpha.20260817040003`, cjpm `1.1.3` |
| Evidence checksums | [`artifacts/checksums.txt`](artifacts/checksums.txt) |

完整 runner、SDK executable digest 与 compiler identity 见
[`artifacts/environment.json`](artifacts/environment.json)，结构化 gate 状态见
[`artifacts/manifest.json`](artifacts/manifest.json)。

## Gate state

| Gate | Status | Evidence |
| --- | --- | --- |
| Source-only release tree | PASS | allowlist 215 files；不包含 VCS、target、cache 或 Native binary |
| Complete public API snapshot | PASS | 1,071 declarations；10 reviewed 2.0 deltas |
| Runtime startup freeze | PASS | Pure late-init、version mismatch、provider conflict、activation failure、concurrent race |
| Pure Cangjie core | PASS | 521 passed, 0 failed |
| Core coverage | PASS | line 60.1%（5,407/8,998）；branch 41.7%（4,205/10,090） |
| Standards required | PASS | 2,110/2,110（Schema required、JSONPath CTS、JSON Patch） |
| Schema optional formats | PASS | 3,074/3,074 aggregate |
| Examples and external consumers | PASS | examples、macro/literal、algorithms、schema formats completed |
| Custom Native | PASS | package、external consumer、Clang/GCC targeted gate |
| yyjson advanced backend | PASS | 11/11 package tests and external consumer |
| Sanitizers | PASS | ASan、UBSan、LSan gate completed |
| Differential fuzz | PASS | 当前候选 deterministic 5,000 cases；50,000-case 扩展证据来自同一 production source 的 `d8f7a512` |
| yyjson symbol isolation | PASS | vendored 0.12.0 与 pinned 0.11.1 的四种 co-link 组合 |
| Windows Pure cross build | PASS | 同一 production source 的 `d8f7a512` 完成 `x86_64-w64-mingw32` build；未宣称 Windows runtime qualified |
| Package rehearsal | PASS | nine unpublished 2.0.0 `.cjp` artifacts and registry-style consumers |
| Three-library performance | PASS | 36/36 workloads, 11 rounds；规定的一次 noisy rerun 已完成 |
| Native acceleration | PASS | 11 rounds；广告 read/write 均提升至少 5%，普通 workload 无超过 5% 回退 |
| Hosted CI | **PR PASS / MAIN PENDING / BLOCKING** | PR #1 run `33039594558` 全部通过；合并后 `main` workflow 尚未执行 |
| Annotated tag | **NOT RUN** | 候选已验证但未打 tag |
| Registry publish | **NOT RUN** | 未发布任何 package |

完整 fresh-source、core coverage、扩展 fuzz、co-link、Windows cross build 和 package rehearsal
日志位于 [`artifacts/logs/`](artifacts/logs/)。本候选相对 local fresh-source 日志绑定的
`497245f5` 只修改 schema formats compiler discovery、测试/CI、文档与 evidence；当前 build hook
已由本地 `-O2` package rehearsal 和 hosted standards/consumer jobs 验证。Cangjie 编译日志仍
包含 SDK unittest 宏展开产生的 warning；本表的 Native compiler PASS 指仓库定义的
Clang/GCC `-Werror` gate，
不把宏生成告警误写为“零告警”。

## General performance evidence

最终重跑保留全部 36 个共同 workload：13 个三库 CV 均不超过 5%，23 个标记 noisy，
没有因 CV 删除行。2.0 固定门槛 workload 的 yjson/cjfast 两侧 CV 均不超过 5%。

| Workload | yjson | cjfast_json | Y/C | yjson wins | CV Y/C |
| --- | ---: | ---: | ---: | ---: | ---: |
| Large Array encode / string | 46.080 µs | 76.117 µs | 0.608x | 11/11 | 0.53% / 1.10% |
| ProfileBundle encode / bytes | 10.344 µs | 12.546 µs | 0.816x | 11/11 | 2.73% / 3.89% |
| ProfileBundle encode / string | 10.767 µs | 12.338 µs | 0.845x | 11/11 | 2.13% / 4.59% |
| Deep Nested encode / string | 63.552 µs | 74.500 µs | 0.856x | 11/11 | 1.18% / 0.64% |

完整表、CSV、JSON、metadata、raw samples 与 preflight 位于
[`artifacts/performance/general/`](artifacts/performance/general/)。原始结果 archive SHA-256 为
`8b3dd8776de9409df8252ce4c338089f8ea4e87ad29a30d817f59fd671fed76d`。

## Native acceleration evidence

第一批仅因普通 `readNumericArray` 的 Native CV 为 6.85% 被整批丢弃；按规则完整重跑后
所有行双方 CV 均不超过 5%，最终批次如下。

| Case | Pure | Native | N/P | Native wins | CV P/N |
| --- | ---: | ---: | ---: | ---: | ---: |
| writeNumericBytes | 2.354 ms | 0.559 ms | 0.238x | 11/11 | 1.10% / 4.52% |
| readNumericDocument | 2.148 ms | 1.211 ms | 0.564x | 11/11 | 2.42% / 4.01% |
| writeNumericArray | 7.185 ms | 7.233 ms | 1.007x | 4/11 | 2.72% / 2.87% |
| readNumericArray | 2.746 ms | 2.703 ms | 0.984x | 6/11 | 3.02% / 4.06% |
| writeEscapedStrings | 1.616 ms | 1.612 ms | 0.997x | 6/11 | 3.41% / 3.13% |
| writeEscapedBytes | 1.365 ms | 1.366 ms | 1.001x | 5/11 | 2.17% / 4.05% |
| writePlainStrings | 1.288 ms | 1.278 ms | 0.992x | 5/11 | 2.89% / 4.05% |

完整结果位于 [`artifacts/performance/native/`](artifacts/performance/native/)，原始结果
archive SHA-256 为
`7c97d0419a67621eb25c66964c315e92a312ba679d9f0dbbb09df42bcc89275b`。

## Decision

```text
Local fresh-source simulation: PASS
General performance qualification: PASS after required full rerun
Native acceleration qualification: PASS after required full rerun
Hosted CI execution: PR PASS; MERGED MAIN PENDING
Hosted CI policy: BLOCKING
Release decision: PR CANDIDATE VERIFIED; MERGED MAIN PENDING; TAG NOT RUN; REGISTRY PUBLISH NOT RUN
```

Linux x86_64 是完整 qualified 平台。Windows x86_64 仅完成 Pure cross build；macOS 与
ARM64 未验证。稳定发布流程见
[`docs/maintainers/releasing.md`](../../docs/maintainers/releasing.md)。
