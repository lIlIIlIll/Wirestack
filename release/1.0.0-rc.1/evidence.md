# yjson 1.0.0-rc.1 release evidence

本页记录当前候选源码的可审计 release gate 状态。它取代旧 hardening round 中未绑定
commit 的 PASS 快照；旧 external consumer PASS 因进程退出传播和默认多态路径随后发生
修复而视为 `STALE`，不能作为当前候选的发布证据。

## Identity

| Field | Value |
| --- | --- |
| Planned release identity | `1.0.0-rc.1` |
| Candidate source commit | `42c79d2f271b756775583a2ce09b2ce64cb6497b` |
| Evidence generated | `2026-08-21T20:06:45Z` |
| cjpm manifest version | `1.0.0`（cjpm 不接受 prerelease 后缀；未发布） |
| Release scripts revision | candidate source commit |
| Runner | `Arch`, Linux x86_64, glibc 2.44 |
| CPU | Intel Core i7-8700, 6 cores / 12 logical CPUs |
| SDK | Cangjie `1.1.0-alpha.20260817040003 (cjnative)`, cjpm `1.1.3` |
| SDK executable digests | `cjc` `02c01c8…57d3e`; `cjpm` `23a1dbc5…d572f` |
| Evidence checksums | [`artifacts/checksums.txt`](artifacts/checksums.txt) |

完整机器可读 identity 见 [`artifacts/environment.json`](artifacts/environment.json) 和
[`artifacts/manifest.json`](artifacts/manifest.json)。

## Current gate state

| Gate | Status | Evidence |
| --- | --- | --- |
| Source-only release tree | PASS | 117 files；拒绝 `target/`、object、archive、shared library 与未声明 benchmark artifact |
| Public API inventory | PASS | 24 entries |
| Pure Cangjie core | PASS | 505 passed, 0 failed |
| Examples and macro consumer | PASS | external macro consumer completed normally |
| Custom Native | PASS | 9 passed；external consumer completed normally |
| yyjson Direct | PASS | 6 passed；external consumer completed normally |
| Clang/GCC warning gates | PASS | targeted native builds completed under both compilers |
| Sanitizers | PASS | ASan, UBSan and LSan gate completed |
| Differential fuzz | PASS | deterministic short 5,000 and extended 50,000 cases |
| yyjson symbol isolation | PASS | vendored 0.12.0 plus pinned 0.11.1 fixture, hidden-local policy |
| Package rehearsal | PASS | five `.cjp` artifacts; registry-style consumer rehearsal completed |
| Hosted CI | **NOT RUN / NON-BLOCKING** | release owner explicitly approved local evidence as sufficient for this RC |
| Annotated tag / registry publish | **NOT RUN** | not performed as part of this evidence update |

The successful local transcript is
[`local-fresh-checkout.log.gz`](artifacts/logs/local-fresh-checkout.log.gz), and the package
rehearsal transcript is [`package-rehearsal.log`](artifacts/logs/package-rehearsal.log).

## CI and release decision

```text
Local fresh-checkout simulation: PASS
Hosted CI execution: NOT RUN
Release blocking policy: NON-BLOCKING
Exception approval: release owner instruction, 2026-08-22
Approval rationale: hosted CI is not required for this release candidate
Release decision: ELIGIBLE FOR RC TAG; TAG/PUBLISH NOT YET RUN
```

因此 hosted CI 的 `NOT RUN` 不再阻止本次 RC。`1.0.0-rc.1` 当前仍是绑定 exact SHA 的
locally validated source candidate；创建 annotated tag 并记录 tag object 后，它才成为
不可变 prerelease artifact。

## Audit trail

本轮没有隐藏失败重跑：前三次 fresh-checkout 暴露并修复了 release source manifest
遗漏；第四次通过所有仓库内 gate，但因缺少独立 yyjson 0.11.1 fixture 而退出。最终运行
使用官方 0.11.1 source fixture 并完整通过。所有失败 transcript 均保存在
[`artifacts/logs/`](artifacts/logs/)；fixture tarball 不入库，其来源、版本与 SHA-256 记录在
machine-readable manifest 中。

Package rehearsal 生成的五个候选 artifact 保存在 [`artifacts/packages/`](artifacts/packages/)。
这些 artifact 仅用于本地验收，不代表 registry publish。

## Remaining release actions

1. 创建 annotated tag `1.0.0-rc.1`，再记录 tag object、UTC 时间与远程引用。
2. 若执行 registry publish，追加 registry 返回值和 artifact URL。
3. 正式 1.0 发布前提供并验证实际可用的私密安全报告渠道；当前
   [`SECURITY.md`](../../SECURITY.md) 明确记录了该缺口。

稳定发布流程见 [`docs/maintainers/releasing.md`](../../docs/maintainers/releasing.md)。
