# 0.1.0 发布证据

本页按 `docs/maintainers/releasing.md` 的流程记录候选状态。提交、SDK、runner、命令、
日志与 checksum 必须绑定到对应 gate 的 evidence；本页只记录不可重复的一次性结果，
方法见 `docs/performance/methodology.md` 与 `docs/maintainers/releasing.md`。

## 1. 冻结身份

- Candidate commit: `87410840ba64464a8c091a0ea0880e90edb5cb00`
- 版本线: 九包 `0.1.0`（允许 breaking change，不提供旧 API alias）
- SDK: Cangjie `1.1.0-alpha.20260829040003` (cjnative)
- 状态: 候选冻结与 gate 执行**尚未开始**。以下 hosted/本地 gate 均为 `NOT RUN`，
  本页是待回填模板，**不代表任何 PASS**。hosted 结果必须在对应 workflow 实际运行后
  回填，不能从源码可移植性推断 PASS（`docs/maintainers/testing.md`）。

## 2. 阻断 gate 状态

```text
Local Linux fresh-candidate: NOT RUN
Hosted Linux CI: NOT RUN
Hosted Windows Pure: NOT RUN
Hosted macOS Pure: NOT RUN
Coverage: NOT RUN
Pages deployment: NOT RUN
Release policy: BLOCKING（见下）
```

> 阻断说明：发布前必须关闭 `docs/maintainers/releasing.md` 第 2 节全部 blocker，
> 包括 release performance 的 workload、checksum、RSS、交替/反转 A/B 前置，以及
> Native package 从 staged source 独立构建（含 `native/yjson_float_format.c` 与
> vendored yyjson 闭包）。当前 native_accel 资格批次尚未运行。

## 3. 所需 evidence 清单（回填时逐项绑定）

每项必须记录：commit、精确 SDK（resolved version + archive checksum）、runner 身份、
命令、日志与 checksum；本地 PASS 不能写成 hosted PASS。

- [ ] Local Linux fresh-candidate：`scripts/ci_fresh_checkout.sh` 完整日志与 exit code
- [ ] Hosted Linux CI（push + PR 两条路径）：workflow run id、job 列表、SDK resolved version
- [ ] Hosted Windows Pure / macOS Pure：workflow run id、job 列表
- [ ] Coverage：job 输出、`coverage-baseline.toml` 门禁结果
- [ ] Pages deployment：URL、run id、artifact checksum
- [ ] Native acceleration formal gate：11 轮、固定 CPU、交替/反转 A/B、RSS
  （`/usr/bin/time -v`）、每 case 内容 checksum（`CHECKSUM <case> <fnv1a-hex>` 行）、
  原始报告与 manifest；广告 workload 门槛
  `Native/Pure <= 0.95` 且 wins >= 6/11，普通 workload 回退不超过 5%，
  两侧 CV 均不超过 5%（`scripts/json_native_accel_perf_run.py`）
- [ ] Native package staged-source 独立构建：`scripts/release_package_stage.py` +
  `scripts/release_temp_tree.py --enforce-clean` + registry rehearsal
- [ ] 性能方法：`docs/performance/methodology.md` 与 `docs/performance/README.md`
  要求的 workload、checksum、RSS、交替/反转 A/B、跨 profile 资格

## 4. 已知的历史测量边界

- `docs/performance/results/2026-08-21-cjfast-json.md`、
  `2026-08-22-go-yyjson.md`、`2026-08-24-stream-backends.md` 与
  `benchmarks/t9-ports/T9-EXPANSION-PLAN.md` 第 7 节数字均为 legacy/diagnostic
  快照，**不自动成为 0.1.0 声明**；正式结论以上述清单回填后为准。
