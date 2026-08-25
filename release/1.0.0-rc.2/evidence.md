# yjson 1.0.0-rc.2 release evidence

本页记录 rc.2 候选源码的 Linux 验收状态。它不会覆盖或更新 rc.1 evidence；所有 PASS
均绑定候选提交和随仓库提交的 transcript、机器可读摘要或 checksum。

## Identity

| Field | Value |
| --- | --- |
| Planned release identity | `1.0.0-rc.2` |
| Candidate source commit | `15d264c34123ff2624572d946c55c7395ccd7fe9` |
| Evidence generated | `2026-08-25T10:34:00Z` |
| cjpm manifest version | `1.0.0`（cjpm 不接受 prerelease 后缀；未发布） |
| Qualification runner | `Arch`, Linux x86_64, glibc 2.44 |
| Qualification SDK | Cangjie `1.1.0-alpha.20260817040003`, cjpm `1.1.3` |
| Performance runner | `ubuntu2223131`, Linux x86_64, glibc 2.35, CPU 8 pinned |
| Performance SDK | Cangjie `1.1.0-alpha.20260803040049`, cjpm `1.1.3`, stdx `0.0.3` |
| Evidence checksums | [`artifacts/checksums.txt`](artifacts/checksums.txt) |

完整 runner、SDK executable digest 与 compiler identity 见
[`artifacts/environment.json`](artifacts/environment.json)，结构化 gate 状态见
[`artifacts/manifest.json`](artifacts/manifest.json)。

## Gate state

| Gate | Status | Evidence |
| --- | --- | --- |
| Source-only release tree | PASS | allowlist 176 files；不包含 VCS、target 或 build cache |
| Complete public API snapshot | PASS | 1,065 declarations；38 reviewed deltas |
| Pure Cangjie core | PASS | 535 passed, 0 failed |
| Standards required | PASS | 2,110/2,110（Schema required、JSONPath CTS、JSON Patch） |
| Schema optional formats | PASS | 3,074/3,074 aggregate；optional format cases 964/964 |
| Examples and macro consumers | PASS | executable completion markers verified |
| Custom Native | PASS | package and external consumer passed |
| yyjson Direct | PASS | 11/11 and external consumer passed |
| Native compiler warnings | PASS | Clang 15 and GCC 16 targeted builds under `-Werror` |
| Sanitizers | PASS | ASan, UBSan and LSan gate completed |
| Differential fuzz | PASS | deterministic 5,000 and 50,000 cases |
| yyjson symbol isolation | PASS | vendored 0.12.0 plus pinned 0.11.1 fixture |
| Package rehearsal | PASS | six unpublished `.cjp` artifacts and registry-style consumers |
| Three-library performance | PASS | 36/36 workloads, 11 rounds, 13 stable and 23 noisy retained |
| Hosted CI | **NOT RUN / NON-BLOCKING** | release-owner policy; local Linux evidence is blocking |
| Annotated tag | **NOT RUN** | candidate is verified but not yet tagged |
| Registry publish | **NOT RUN** | no package was published |

完整 fresh-source transcript 为
[`local-fresh-checkout.log.gz`](artifacts/logs/local-fresh-checkout.log.gz)，package rehearsal
transcript 为 [`package-rehearsal.log`](artifacts/logs/package-rehearsal.log)。Cangjie 编译日志仍
包含 SDK unittest 宏展开产生的 unreachable-branch warning；本表的 warning PASS 只指仓库
定义的 Native C Clang/GCC `-Werror` gate，不把宏生成告警误写为“零告警”。

## Performance evidence

三库结果绑定同一 candidate、SDK、CPU affinity、128 MiB heap 与 rotating-order 设计。
完整 36 行见[公开结果表](../../docs/performance/results/2026-08-25-linux-rc2-three-library.md)，
机器可读 CSV 见[同目录 CSV](../../docs/performance/results/2026-08-25-linux-rc2-three-library.csv)。
CV 只决定 `stable`/`noisy` 标签，不删除 workload。

| Workload | yjson | stdx.json | cjfast_json | Y/S | Y/C | Stability |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Large Map encode / string | 120.094 µs | 259.263 µs | 131.072 µs | 0.465x | 0.917x | stable |
| Large Array encode / string | 107.814 µs | 480.394 µs | 75.520 µs | 0.237x | 1.432x | noisy |
| Unicode decode / bytes | 2.389 µs | 30.037 µs | 1.833 µs | 0.083x | 1.272x | noisy |

完整 raw samples、每轮日志、preflight、metadata 与 portable checksum 位于
[`performance/full-result.tar.gz`](artifacts/performance/full-result.tar.gz)，archive SHA-256 为
`24f1109ca25db2166bc66fde71fddeb46520cdd6fbe2318fedaa7e9de40b25c5`。

## Audit trail and decision

本轮先在本机发现 cjfast_json 所需的 static stdx JSON FFI 不存在，因此没有把本机失败
当成性能结果。Server clean-source preflight 随后暴露 benchmark package allowlist 缺文件；
修复后又发现 checksum 使用绝对路径。两项发布工程缺陷均 amend 到候选提交，旧 SHA 的
测量没有重贴标签。最终 SHA 的 36-workload 结果和 portable checksum 均重新生成并验证。

```text
Local fresh-source simulation: PASS
Package rehearsal: PASS
Exact-SHA performance comparison: PASS
Hosted CI execution: NOT RUN
Hosted CI policy: NON-BLOCKING
Release decision: CANDIDATE VERIFIED; TAG NOT RUN; REGISTRY PUBLISH NOT RUN
```

当前 qualified 平台仍是 Linux x86_64。Windows、macOS 与 ARM64 仅视为未验证但可能支持。
稳定发布流程见 [`docs/maintainers/releasing.md`](../../docs/maintainers/releasing.md)。
