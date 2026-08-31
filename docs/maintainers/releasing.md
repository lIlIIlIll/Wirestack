# 发布 yjson

本页定义可重复流程，不记录一次性结果。每个候选的 commit、SDK、runner、命令、日志和
checksum 必须进入 `release/<version>/evidence.md`。

## 1. 冻结身份

候选绑定 exact commit、九包 `0.1.0` 版本、release graph、工具链和 planned release identity。
发布期间不混入未评审 public API、C ABI 或 generated bridge 变化。

`release/public-cangjie-delta-bfd29.toml` 必须逐项覆盖 snapshot 的全部 removed/added declaration。
每条记录只能属于一个带 rationale 的 review group；存在重复、漏项、`unclassified` 或 pending
group 时，不得把 release graph 改为 `release-ready`。

Hosted CI 每七天选择一次最新的完整 dated nightly。一个候选的所有 hosted job 必须使用同一
精确 SDK，并在 evidence 中记录 resolved version 和 archive checksum。手工资格运行可以显式
指定一个完整 nightly。API reference 使用 `cjdoc 0.6.0` at commit
  `2e8c8ecc849ba77d5209f4546cdbb2129b7b17fb`

archive、binary 和 action identity 必须通过仓库中的 checksum/SHA 配置验证。

## 2. 阻断 gate

以下失败阻止发布：

1. API/C ABI inventory、release graph 或 package pairing 失败；
2. core、examples、macro/codec/algorithms consumer 失败；
3. fixed standards suite 或 optional format suite 不满足预期 cardinality；
4. release performance 缺 workload、checksum、RSS、交替/反转 A/B，或确认发生阻断 regression；
5. Native package 不能从 staged source 独立构建；
6. warning、ASan、UBSan、LSan、differential fuzz 或 symbol isolation 失败；
7. manifest、source-only staging、license、vendored checksum 或 isolated consumer 失败；
8. documented options、error、view、stream、concurrency 或 lifecycle contract 失败；
9. source archive 包含 build output、cache、symlink 或未声明 artifact；
10. qualified platform 存在未处置 correctness/security blocker；
11. GitHub Actions Linux、Windows 或 macOS Pure gate，或 Linux Native gate 失败；
12. coverage 低于 project line 80% / branch 70% 或 patch line 90% / branch 80%；
13. cjdoc source qualification、九包生成、known-gap policy、链接或可复现性检查失败。

高 CV 不自动隐藏结果。Native acceleration 的正式 gate 使用 11 轮、固定 CPU、交替进程顺序；
广告 read/write workload 要求 `Native/Pure <= 0.95` 且至少赢 6/11，普通 workload 不得回退
超过 5%，双方 CV 均不超过 5%。不稳定批次整体作废并完整重跑一次；第二批仍不稳定即不具备
发布资格。

## 3. 分开记录证据

```text
Local Linux fresh-candidate: PASS / FAIL / NOT RUN
Hosted Linux CI: PASS / FAIL / NOT RUN
Hosted Windows Pure: PASS / FAIL / NOT RUN
Hosted macOS Pure: PASS / FAIL / NOT RUN
Coverage: PASS / FAIL / NOT RUN
Pages deployment: PASS / FAIL / NOT RUN
Release policy: BLOCKING / NON-BLOCKING
```

本地 PASS 不能写成 hosted PASS。`0.1.0` 要求发布 PR 和合并后的 `main` workflow 都通过；
push、PR、CI、merge、tag 和 publish 是不同状态。

## 4. Stage 与 rehearsal

创建 source-only 工作树：

```terminal
python3 scripts/stage_source_tree.py /tmp/yjson-source-stage
python3 scripts/stage_source_tree.py --check /tmp/yjson-source-stage
```

目标必须为空且不能与源码树重叠。stage 拒绝 build output、可执行文件、archive、
profile/coverage 文件和 symlink。

按 release manifest 创建候选树：

```terminal
python3 scripts/release_temp_tree.py /tmp/yjson-release-stage --enforce-clean
```

该命令只复制 `release/release-files.txt` 中的路径，并再次执行 source-only 检查。正式候选
要求 clean checkout，并生成 `release/candidate-provenance.json`。该文件记录 commit、tree、
manifest digest 和 payload digest；provenance 文件自身不计入 payload digest。每个被收录
cjpm project 的 `src/**/*.cj`、`cjpm.lock` 和 `build.cj`（若存在）必须完整入清单；被收录
脚本的本地依赖也必须闭合。

API inventory 和 core test 会写临时文件，因此 CI 在候选清单复制出的诊断树中运行这些检查。
registry rehearsal 使用未修改的正式候选树，并在构建前后验证清单和 provenance。

完整本地 Linux 模拟：

```terminal
scripts/ci_fresh_checkout.sh
```

registry rehearsal 从候选树执行 API inventory、九包独立 staging/build、external consumers、
third-party notice、vendored checksum 和 exported symbol 检查。SDK build 不属于 yjson package
release gate。

## 5. API reference 与 Pages

先从固定 source 构建并 qualification cjdoc，再生成九包 site：

```terminal
cjdoc_path=$(scripts/codex_cangjie_env python3 scripts/prepare_cjdoc.py)
scripts/codex_cangjie_env python3 scripts/generate_api_docs.py \
  --cjdoc "$cjdoc_path" \
  --output /tmp/yjson-api-docs-0.1.0
```

目标必须不存在。生成结果包含顶层 `api-docs.json`、index 和每包 Doc IR/HTML。允许的 cjdoc
0.6 gaps 必须精确匹配 `release/cjdoc-policy.toml`。

PR 只生成并上传 Pages artifact；合并到 `main` 后的 workflow 才部署。发布 evidence 记录
deployment URL、run id 和 artifact checksum。本地 HTML 不能代替 Pages deployment PASS。

## 6. Tag 与 publish

所有 blocker 关闭且 evidence review 完成后：

1. 通过普通 pull request 合并到 `main`；
2. 等待合并 commit 的全部 required workflow 通过；
3. 在该 commit 创建 `0.1.0` annotated tag；
4. 创建 GitHub Release；
5. 上传九个 `.cjp`、`checksums.txt`、`manifest.json` 和 `environment.json`；
6. 验证 release assets 和 Pages 指向已验收 commit。

中心 registry publish 是单独动作；未获授权时保持 unpublished。发布动作、URL 和 checksum
追加到不可变 evidence，后续候选不得覆写。

测试 mapping 见 [testing.md](testing.md)，性能规则见
[performance methodology](../performance/methodology.md)。
