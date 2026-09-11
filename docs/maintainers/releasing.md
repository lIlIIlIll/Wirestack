# 发布 yjson

按以下流程准备和发布候选版本。每个候选的提交、SDK、运行器、命令、日志和
校验和必须进入 `release/<version>/evidence.md`。

## 1. 固定候选版本

候选记录精确提交、九包 `0.1.0` 版本、发布图、工具链和计划发布的版本信息。
发布期间不混入未经评审的公开 API、C ABI 或生成代码接口变化。

`release/public-cangjie-delta-bfd29.toml` 必须逐项覆盖快照的全部删除和新增声明。
每条记录只能属于一个说明了理由的评审组；存在重复、漏项、`unclassified` 或尚未完成评审的组时，不得把发布图改为 `release-ready`。

托管 CI 固定使用 Cangjie STS `1.1.3`。一个候选的所有托管 CI 任务必须使用同一
精确 SDK 版本，并在证据中记录解析出的版本和归档校验和。手工验证可以显式指定
一个 STS SDK。API 参考文档按 `release/cjdoc-tool.toml` 使用 `cjdoc 0.7.2`，
提交为 `fe0b5a5294c6d98dc1e6fb7d6d41cb5e9b04d4c0`。

本次基线迁移只改变发布资格和托管 CI 使用的 SDK，不自动提高各包 manifest 的
`cjc-version` 兼容性声明；包 manifest 的兼容性下限若要提高，必须单独完成公开
兼容性评审。

归档、二进制文件和 Action 版本必须通过仓库中的校验和/SHA 配置验证。

## 2. 发布前检查

以下任一项失败都会阻止发布：

1. API/C ABI 接口清单、发布图或包版本配对失败；
2. 核心包、示例、宏、codec 或算法使用方测试失败；
3. 固定标准测试集或可选格式测试集不满足预期用例数；
4. 发布性能测量缺少负载、校验和、RSS、交替与反转 A/B，或确认发生阻止发布的性能回退；
5. Native 包不能从暂存源码独立构建；
6. 编译警告检查、ASan、UBSan、LSan、差分模糊测试或符号隔离失败；
7. 清单、仅含源码的暂存、许可证、内置第三方源码校验和或隔离的使用方测试失败；
8. 文档规定的选项、错误、视图、流、并发或生命周期约定失败；
9. 源码归档包含构建产物、缓存、符号链接或未声明产物；
10. 发布验证平台存在尚未处理的正确性或安全问题；
11. GitHub Actions Linux、Windows 或 macOS Pure 检查，或 Linux Native 检查失败；
12. 覆盖率低于项目行 80%、分支 70%，或改动行 90%、分支 80%；
13. cjdoc 源码验证、九包生成、已知限制清单、链接或可复现性检查失败。

Pure 的普通 Release 验收使用 `json_pure_perf_compare.py --gate-mode release`：
它要求结果稳定且没有超过政策阈值的回退，不要求 candidate 相对 baseline 提升。
只有 Release notes 明确宣称某项性能优化时，才额外使用
`--gate-mode optimization --target-case ...` 验证该优化目标；优化目标未达标不应
被误写成所有 Release 的通用性能失败。

即使 CV 过高，也要保留并报告结果。Native 加速的正式检查使用 11 轮、固定 CPU、交替进程顺序；
对外宣称加速的读写负载要求 `Native/Pure <= 0.95` 且至少赢 6/11，普通负载不得回退
超过 5%，双方 CV 均不超过 5%。不稳定批次整体作废并完整重跑一次；第二批仍不稳定即不具备
发布资格。

## 3. 记录各项检查结果

```text
Local Linux fresh-candidate: PASS / FAIL / NOT RUN
Hosted Linux CI: PASS / FAIL / NOT RUN
Hosted Windows Pure: PASS / FAIL / NOT RUN
Hosted macOS Pure: PASS / FAIL / NOT RUN
Coverage: PASS / FAIL / NOT RUN
Pages deployment: PASS / FAIL / NOT RUN
Release policy: BLOCKING / NON-BLOCKING
```

本地 PASS 不能写成托管 CI 的 PASS。`0.1.0` 要求发布 PR 和合并后的 `main` 工作流都通过；
分别记录推送、PR、CI、合并、打标签和发布状态。

## 4. 准备源码并演练发布

创建仅含源码的工作树：

```terminal
python3 scripts/stage_source_tree.py /tmp/yjson-source-stage
python3 scripts/stage_source_tree.py --check /tmp/yjson-source-stage
```

目标必须为空且不能与源码树重叠。暂存目录拒绝构建产物、可执行文件、归档、
性能分析或覆盖率文件和符号链接。

按发布文件清单创建候选树：

```terminal
python3 scripts/release_temp_tree.py /tmp/yjson-release-stage --enforce-clean
```

该命令只复制 `release/release-files.txt` 中的路径，并再次执行仅含源码的检查。正式候选
要求干净的检出版本，并生成 `release/candidate-provenance.json`。该文件记录提交、Git 树、
清单摘要和文件内容摘要；来源记录文件自身不计入文件内容摘要。每个收录的 cjpm 项目的 `src/**/*.cj`、`cjpm.lock` 和 `build.cj`（若存在）必须完整入清单；被收录
脚本依赖的本地文件也必须收录。

API 接口清单和核心包测试会写临时文件，因此 CI 在候选清单复制出的诊断树中运行这些检查。
包仓库发布演练使用未修改的正式候选树，并在构建前后验证清单和来源记录。

完整本地 Linux 模拟：

```terminal
scripts/ci_fresh_checkout.sh
```

包仓库发布演练从候选树执行 API 接口清单、九包独立暂存和构建、外部使用方测试、
第三方声明、内置第三方源码的校验和，以及导出符号检查。SDK 构建不属于 yjson 包
发布检查。

## 5. 生成 API 文档并部署 Pages

先从固定源码构建并验证 cjdoc，再生成九个包的文档站点：

```terminal
cjdoc_path=$(scripts/codex_cangjie_env python3 scripts/prepare_cjdoc.py)
scripts/codex_cangjie_env python3 scripts/generate_api_docs.py \
  --cjdoc "$cjdoc_path" \
  --output /tmp/yjson-api-docs-0.1.0
```

目标必须不存在。生成结果包含顶层 `api-docs.json`、索引及每包的 Doc IR 和 HTML。允许的 cjdoc
不支持项必须精确匹配 `release/cjdoc-policy.toml`。

PR 只生成并上传 Pages 产物；合并到 `main` 后的工作流才部署。发布证据记录
部署 URL、运行 ID 和产物校验和。本地生成 HTML 后，还需要单独确认 Pages 部署成功。

## 6. 打标签并发布

所有阻塞问题关闭且证据评审完成后：

1. 通过普通 PR 合并到 `main`；
2. 等待合并提交的全部必需工作流通过；
3. 在该提交创建 `0.1.0` 附注标签；
4. 创建 GitHub Release；
5. 上传九个 `.cjp`、`checksums.txt`、`manifest.json` 和 `environment.json`；
6. 验证发布附件和 Pages 指向已验收的提交。

向中心包仓库发布是单独操作；未获授权时不得发布。发布动作、URL 和校验和
追加到发布记录，后续候选不得覆写。

测试对应关系见 [testing.md](testing.md)，性能规则见
[性能方法](../performance/methodology.md)。
