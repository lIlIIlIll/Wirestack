# 发布 yjson

本页定义可重复流程，不记录一次性结果。每次候选的 commit、SDK、runner、命令结果、日志与
checksum 必须进入 `release/<version>/evidence.md`。

## 1. 冻结身份

候选必须绑定 exact commit、所有 package 的版本配套、工具链身份和 planned release
identity。发布期间不混入未评审 public API 或生成代码 bridge 变化。

## 2. 执行阻断 gate

以下失败阻止发布：

1. API/ABI inventory 或 package-pairing 校验失败；
2. core、examples、macro/literal consumer 失败；
3. 固定 standards suites 失败；
4. release performance 表缺库、缺共同 workload 或确认发生阻断 regression；
5. staged Native package 不能从自身 source 独立构建；
6. warning、ASan、UBSan、LSan 或 differential fuzz 失败；
7. manifest、source staging、license、C ABI 或 symbol isolation 失败；
8. external consumer 或 documented lifecycle 失败；
9. source archive 包含 build output 或未声明 artifact；
10. qualified platform 上存在未处置的 correctness/security blocker；
11. GitHub Actions 的 Linux、Windows 或 macOS 必需 Pure gate，或 Linux Native gate 失败；
12. 九包 `cjdoc` qualification、公共 API 注释覆盖、示例、链接、安全或可复现性检查失败。

高 CV 不自动阻断，也不能成为隐藏结果的理由；标记 noisy 后由 release owner 结合配对方向、
历史基线和 workload 重要性处置。

Native acceleration 是更严格的独立阻断 gate：广告 read 和 write workload 必须各自达到
`Native/Pure ≤ 0.95` 且至少赢 6/11，普通稳定 workload 不得回退超过 5%，所有行双方
CV 必须 ≤ 5%。出现 noisy 行时丢弃整批并完整重跑一次；第二批仍不稳定或任一性能条件失败，
则 `0.1.0` acceleration qualification 不完成，不能只隐藏失败行或宣传局部结果。

## 3. 记录 local 与 hosted 状态

```text
Local fresh-checkout simulation: PASS / FAIL / NOT RUN
Hosted CI execution: PASS / FAIL / NOT RUN
Release blocking policy: BLOCKING / NON-BLOCKING
```

本地 PASS 不能写成 hosted PASS。`0.1.0` release 要求发布 PR 与合并后的 `main` workflow
均通过；不得以本地证据替代 hosted CI 或 Codecov。

## 4. 审查平台声明

只对实际完成 SDK、build、tests、standards、sanitizer、fuzz 和 consumer gate 的平台声明
qualified。源码看起来可移植，只能支持 `unverified / potentially supported` 表述。

## 5. Stage 与 rehearsal

先创建完整的 source-only 工作树，并验证其中没有 build output、cache、benchmark result 或
symlink：

```terminal
python3 scripts/stage_source_tree.py /tmp/yjson-source-stage
python3 scripts/stage_source_tree.py --check /tmp/yjson-source-stage
```

目标目录必须为空，且不能与源码目录重叠。第一个命令成功时输出复制文件数和目标路径，第二个
命令输出 `source-only tree verified`。stage 从 Git index 导出 release roots，并拒绝 build 目录、
可执行二进制、archive、profile/coverage 文件和 symlink。`scripts/test_stage_source_tree.py`
覆盖排除规则、非空目标和对抗样本。

然后按 release manifest 创建候选树：

```terminal
python3 scripts/release_temp_tree.py /tmp/yjson-release-stage
```

候选目录也必须为空。该命令只复制 `release/release-files.txt` 中列出的文件，并再次执行
source-only 检查。它还要求 manifest 包含全部 `*_test.cj` 和被收录脚本引用的本地脚本；
新增测试或脚本依赖未入清单时立即失败。CI 的 `registry-rehearsal` 从该候选树实际执行
`check_api_inventory.py` 和 `cjpm test`，再继续 package rehearsal：

- 检查 release manifest 不含 path dependency。
- 按 release graph 顺序独立构建全部九个 package。
- 运行 registry-style external consumers。
- 核对 third-party notice、vendored checksum 和 exported symbols。

SDK build 不属于普通 yjson package release gate。

## 6. Tag 与 publish

所有 blocker 关闭且 evidence review 完成后，先通过普通 pull request 合并到 `main`，再等待
`main` workflow 通过。随后在该 `main` commit 创建 `0.1.0` annotated tag 和 GitHub Release，
并上传九个 `.cjp`、`checksums.txt`、`manifest.json` 与 `environment.json`。中心 package registry
发布是单独动作；未获授权时保持 unpublished。

发布动作、artifact URL 与 checksum 追加到该版本不可变 evidence；后续候选不得覆写旧记录。

测试层与 job mapping 见 [testing.md](testing.md)，性能发布规则见
[performance methodology](../performance/methodology.md)。
