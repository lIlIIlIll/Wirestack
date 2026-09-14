# 0.1.0 发布证据

本页记录 `0.1.0` 候选的可审计验收状态。每个结果绑定测量提交、源码身份、
SDK、runner、命令和校验和；不把本地结果写成 hosted 结果，也不把诊断性能数据
写成发布资格。

## 1. 冻结身份

| Field | Value |
| --- | --- |
| Planned release identity | `0.1.0` |
| Candidate measured commit | `4766daa7ac88a5ad0869cfa2dbdb12c63acd0161` |
| Candidate measured tree | `ccbee2fa194180c66374d44852c0122c30b7e9a6` |
| Package manifest | 九个 package，版本均为 `0.1.0` |
| Release graph | `release/release-graph.toml`；status=`release-ready` |
| Evidence updated | `2026-09-13` |
| Formal performance runner | `Server`；Linux x86_64；CPU 1，sibling 49 |
| Release qualification SDK | Cangjie STS `1.1.3`；正式七库、三库和 Pure 测量均记录 `cjc/cjpm 1.1.3` |
| Hosted PR SDK | Cangjie STS `1.1.3`；resolution=`pinned-sts`；latest completed candidate run [`34778796451`](https://github.com/lIlIIlIll/yjson/actions/runs/34778796451) 的 28 jobs 全部通过 |


此前记录的本地编译器 `cjc` SHA-256
`bc0f32df9c610dcbb05f437552ff57ec6c6e075a54721f46cc9c882a62d2d836`，
以及 `cjpm` SHA-256
`b867fca2fd0d4bc19bf195e7872f6f13d5019fd3ba5f409291814f7c5bdfa313`
属于旧的 `1.1.0-alpha.20260829040003` 工具链。发布基线已迁移到 STS
`1.1.3`，旧工具链结果不能作为新基线的资格证据。

旧 Hosted PR 为 [#26](https://github.com/lIlIIlIll/yjson/pull/26)，其
`1.1.0` run [`34563502643`](https://github.com/lIlIIlIll/yjson/actions/runs/34563502643)
因 `Seven-library evidence drift` 失败，不能写成新基线的 hosted PASS。


## 2. Gate 状态

| Gate | Status | Evidence |
| --- | --- | --- |
| Public API/C ABI mechanical inventory | PASS | `1094` Cangjie declarations；九包 inventory；C ABI delta 全部 `reviewed-for-0.1.0` |
| Public API migration review | PASS | `release/public-cangjie-delta-bfd29.toml` 为 `approved-for-release`；17 个 reviewed delta，native activator removal 与 writer seam 分组独立 |
| Local Linux fresh candidate | PASS (historical) | `scripts/ci_fresh_checkout.sh` 的 qvt/STS `1.1.3` 结果曾通过；当时 release tree 为 `292` files，早于当前 `297` 项 manifest；当前候选的 source-only、registry rehearsal 和 freshness 由下方 hosted run 覆盖 |
| Hosted PR CI | **NOT RUN (current RSS checkpoint)** | 上一次已完成的 hosted run `34779604448` 的 28 jobs 全部通过，但它早于本地 RSS instrumentation checkpoint；push 当前提交后必须重新运行 |
| Hosted main CI / Pages | PASS (historical) | run [`34511955542`](https://github.com/lIlIIlIll/yjson/actions/runs/34511955542) 的 28 jobs 与 Pages 通过；它不是 `1.1.3` 基线下当前候选的合并后 run |
| Coverage | PASS (historical) | 上一次候选 run 的 `Core Coverage` job 通过；历史 project line `8508/10345=82.2%`、branch `3722/5262=70.7%`，changed core line/branch 均 `100.0%` |
| Source-only staging | PASS (historical) | 上一次候选 run 的 `registry-rehearsal` 在 enforced source-only candidate 上通过；当前 RSS checkpoint 尚未执行 hosted fresh-candidate |
| Package rehearsal | PASS (historical) | 上一次候选 run 的 `registry-rehearsal` job 通过；当前 RSS checkpoint 尚未执行 hosted rehearsal |
| Seven-library matrix | **BLOCKED (RSS missing)** | 当前提交绑定的两批 STS `1.1.3` 归档各含 770/770 单元，CPU 1/sibling 49 idle sample、checksum、identity 和 strict freshness 均通过；但现有归档未记录每个测量进程的 peak RSS，未满足发布检查第 4 项。runner 现已改为写入 GNU `time -v` sidecar 和 `max_rss_kb`，必须在合格 Server 上重新完成两批矩阵 |
| Three-library release performance | **BLOCKED (RSS missing)** | 当前候选的 STS `1.1.3` 远端正式 36-workload 三库矩阵完成 11 轮；3/36 stable、33/36 noisy，完整 raw archive 和复核结果见[当前三库结果](../../docs/performance/results/2026-09-13-release-three-library.md)；现有归档没有 peak RSS。runner 和 summary 已增加 sidecar 校验，必须重新测量 |
| Pure baseline/candidate qualification | **BLOCKED (RSS missing)** | [当前 Pure 结果](../../docs/performance/results/2026-09-13-linux-release-pure.md)绑定当前候选，STS `1.1.3` 下 24 case、11 轮、release timing gate `all_ratios_at_most_1_05=true`；现有归档早于 RSS 采集，必须用更新后的 runner 重新记录 peak RSS，不能把 timing PASS 当作发布 PASS |
| Native acceleration | NON-BLOCKING (claim not qualified) | 旧 Native diagnostic 为 `0/36` stable、`36/36` noisy；当前三库结果为 `3/36` stable、`33/36` noisy；两者都不支持本次发布的精确 Native/跨库 acceleration claim，且 noisy 本身不阻断普通 Release |
| Release policy | **BLOCKING** | 历史 API、timing gate 和 hosted CI 曾通过，但当前三类性能证据仍缺少 RSS，且本地 RSS checkpoint 尚未完成 hosted CI；此外仍要求合并到 `main`、合并后 required workflows/Pages 通过，当前没有创建 tag 或 Release |
| Annotated tag / GitHub Release | NOT RUN | Release policy remains blocking; no tag, release, or uploaded assets created |
| Central package registry | NOT RUN | 未授权发布；没有执行 central publication |


### 候选资产摘要（未上传）

当前候选的性能复核资料已分别保存在：

- `benchmarks/results/full-seven-library/2026-09-13-release-4766daa/`：两批七库 raw archive、脚本闭包、身份和 checksum；
- `benchmarks/results/release-performance/2026-09-13-4766daa/yjson-pure-release-4766daa-r4.tar.gz`：Pure 24-case raw archive。
- `benchmarks/results/release-performance/2026-09-13-4766daa/yjson-three-library-release-4766daa-r2.tar.gz`：三库 36-workload raw archive，SHA-256 为 `01cf6df6cbdc20cfbb758b94d705ec9c7c23e5925127c9e4b7c26b7d7a2f6c52`；

这些是仓库中的可审计证据，不是 GitHub Release 上传资产。包仓库 rehearsal 已在
`/tmp/yjson-registry-rehearsal-c88d4e/artifacts/` 生成九个 `.cjp`，但该目录是临时
rehearsal 输出，不是最终上传 bundle；当前候选的 `manifest.json`、`environment.json`
和最终 `checksums.txt` 仍未生成，也没有上传 Release assets。

历史 bundle 只绑定旧 commit `fc050734aefa2509d41e5ebb769d47fa7b18f7b6`，
保留作历史 rehearsal，不能用于当前候选的 GitHub Release。其 `checksums.txt`
SHA-256 为 `3a2b7cfef4623c97c6aa78ff9751b5c726ef5951bc9e6fd336165e1f0f9d690c`。


## 3. 性能证据

### 历史：Deep Nested 修复定向复核 (`13a997c`)

以下结果属于前一候选 `13a997c6f5696814e5e860b3d3d39bbfc79d85bc`：
该提交将 generated object-name 解码的紧凑 ASCII 扫描移入 `JsonFastReader.readRawName`，
保留转义、控制字符、非 ASCII 和非法输入的 checked fallback。回归测试覆盖 String/Bytes、
空名称、畸形名称和未闭合名称。

在本地 Linux x86_64、CPU 8、该历史候选源码上，精确筛选
`ComprehensiveJsonCompareBenchmarks.yjsonStringDecodeDeepNestedProfiles` 的
`cjpm bench` 结果为 `86.20 us`，误差 `±10.22 us`、CV `11.9%`，命令 exit `0`。
同一语料的独立单进程定向测量为：旧候选工作树 `120.5 us`，历史候选工作树
`75.71 us`。这些数字是修复方向的历史本地证据，不是当前 `2758853` 的交替 11 轮
release qualification；target-only A/B 因 CV 超过 5% 而 exit `1`。

这些历史数字不能与当前报告合并或推导跨主机比例。当前正式七库矩阵已绑定
`4766daa7ac88a5ad0869cfa2dbdb12c63acd0161`，完整归档见
`benchmarks/results/full-seven-library/2026-09-13-release-4766daa/`；Hosted run
`34778796451` 已对当前候选通过 strict freshness、checksum、identity 和 summary 校验。

### 历史：三库共同 workload（`b0f16eb`）

以下两批数据绑定旧候选 `b0f16eb`，仅作为修复前的历史阻断记录；它们不代表当前
`13a997c` 的性能资格。

两批均在 `ubuntu2223131`、Cangjie `1.1.0-alpha.20260803040049`、cjpm
`1.1.3`、固定 CPU 8、128 MiB 堆上运行。每批包含完整 36 个 yjson、
stdx.json、cjfast_json 共同 workload，11 轮，workload 旋转、偶数轮反转、
库顺序逐轮旋转。

- 第一批归档 SHA-256：
  `44def26482738ad89e77903d16efee6e458be6c2600ff45839767946693c8bce`
- 第二批归档 SHA-256：
  `dfc9b2f1c623fc7bb2857ad3f3cb4a6248fd59e178f19e876148de3db1986b17`
- 第一批：稳定 `0/36`，noisy `36/36`。
- 第二批：稳定 `2/36`，noisy `34/36`；两批均保留在 runner 归档中，第二批仍 noisy，按方法不再继续重跑。

第二批固定大数组 decode 行为：yjson `103947.506 ns`、cjfast_json
`77994.667 ns`，Y/C=`1.334x`，yjson 仅赢 `1/11`，yjson CV=`12.79%`。
该行及其他 noisy 行只保留方向证据，不发布精确比例；由于第二批仍未满足
CV 门槛，三库正式性能 gate 为 BLOCKING。

### 当前：三库共同 workload（STS `1.1.3`）

正式 runner `scripts/release_performance_compare.sh` 在 Server 的
`ubuntu2223131`、Linux x86_64、CPU 1、128 MiB 堆上执行当前候选。每个
yjson/stdx.json/cjfast_json 共同 workload 完成 11 轮，workload 顺序逐轮旋转、
偶数轮反转，三库顺序逐轮旋转；36/36 workload 完整收集，没有删除 noisy 行。

- Stable：`3/36`；noisy：`33/36`（三库各自 CV 均纳入 stable/noisy 判断）。
- Cangjie STS `1.1.3`；`cjc/cjpm` 版本和环境记录、每轮 raw report 均在归档中；
  metadata 的 `sdk_label` 保留为 runner 原值 `unknown`。
- `cjfast_json_commit=eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65`。
- raw archive：
  `benchmarks/results/release-performance/2026-09-13-4766daa/yjson-three-library-release-4766daa-r2.tar.gz`
  ；SHA-256 为 `01cf6df6cbdc20cfbb758b94d705ec9c7c23e5925127c9e4b7c26b7d7a2f6c52`。

完整 36 行、summary、manifest、metadata、preflight 和复核命令见
[当前三库结果](../../docs/performance/results/2026-09-13-release-three-library.md)。
33 行 noisy 只作为方向和复核数据，不发布稳定的精确跨库排名；timing 和完整性检查
通过，但 runner 未记录 peak RSS，因此当前三库结果不能单独关闭发布性能证据门禁。

### Pure 基线/候选（当前候选，STS `1.1.3`）

正式 runner `scripts/json_pure_perf_compare.py` 在当前候选
`4766daa7ac88a5ad0869cfa2dbdb12c63acd0161`、tree
`ccbee2fa194180c66374d44852c0122c30b7e9a6` 上，以
`175a4b23656ab44d2d139b810e69ac364347297a` 为 baseline，执行 24 个实际
case、11 轮、128 MiB、`--gate-mode release`、`--rebuild --enforce`。CPU 1
与 sibling 49 的 30 秒 idle sample 均为 `0.0%`。

`summary.json` 的 timing gate 为 `all_ratios_at_most_1_05=true`、`passed=true`；
`both_cv_at_most_5_percent=false` 只表示部分行 noisy，按普通 Release 的 timing policy
不阻断回退检查。最大回退为 `yjsonStringEncodePerson` 的 `-3.77%`（ratio `1.038x`），
最大改善为 `yjsonBytesDecodeLargeInt64Map` 的 `24.26%`（ratio `0.757x`）。但该 runner
未采集每个进程的 peak RSS，因此不能满足发布检查第 4 项。

完整 24 行、命令、环境和身份见
[当前 Pure 结果](../../docs/performance/results/2026-09-13-linux-release-pure.md)；
raw archive 为
`benchmarks/results/release-performance/2026-09-13-4766daa/yjson-pure-release-4766daa-r4.tar.gz`，
SHA-256 为 `506504cbe6caf5a87d4c1a699d9855b5ddc4e293fbd15e883487f71a506c2053`。

### 历史：Native / 三库诊断（旧候选，STS `1.1.3`）

`scripts/json_cjfast_perf_run.py` 在 qvt 候选上使用固定 CPU `4`、128 MiB、
11 轮、完整 36 个 yjson/stdx.json/cjfast_json workload 完成，随后由
`scripts/json_cjfast_perf_summary.py` 汇总。该批三个库均完成 11 轮，
稳定 workload 为 `0/36`、noisy workload 为 `36/36`；noisy 只表示不能发布精确的
Native/跨库性能比例或 acceleration claim，不是普通 Release 的阻断条件。

本批 `yjson_commit=533284b9b8e6eee5c65b7fbbc2701ef8f4b35380`、
`cjfast_json_commit=eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65`、
`sdk_label=sts-1.1.3`。yjson source SHA-256 为
`296f2936ae180fb033872337783da83612579261b809ac1080302bdde1ccd36a`，
cjfast source SHA-256 为
`292375e14bb28f1c32da240e27d85e8e55a1fe4a6a8d834598908a02e2761922`。
`manifest.csv`、`metadata.json`、`summary.json`、`summary.csv`、`summary.md`
SHA-256 依次为：
`4360de626ea977cd04b52b0b23fbae00e2bbde0220fbecbf071384314985f045`、
`47dd6a09c4c2e800ee649125f9c294d82bba43479d53ec12ecf198c4e4a2dba3`、
`7180b48f460db5534804ce855326756dbcd10af6235024f02fb080cae7522c72`、
`74b26fecb241365f0b8e21133396209b7c7499ec4b00eadda1ea95e8a77cf888`、
`a273b4bb44b46192dabd3f71762b832c3edba80d61747f0c8053e1244f7ae5c2`。
因此该批保留为 STS `1.1.3` 下的当前诊断；它不具备单独发布精确性能声明的资格，
但 noisy 本身不阻断普通 Release。Native/Pure acceleration claim 仍须另行通过
其专用的稳定性、RSS、checksum 和比例门禁。

### 历史 Native acceleration（`b0`）

在 b0 精确源码上，固定 CPU 4、128 MiB、11 轮、Pure/Native 交替进程，7 个
case 均通过 RSS 和内容 checksum：

| Case | Pure | Native | Native/Pure | Wins | CV P/N |
| --- | ---: | ---: | ---: | ---: | ---: |
| `writeNumericArray` | `4125838.22 ns` | `553839.09 ns` | `0.134x` | `11/11` | `3.96%/3.70%` |
| `writeNumericBytes` | `4568168.44 ns` | `508837.38 ns` | `0.111x` | `11/11` | `3.02%/3.08%` |
| `readNumericArray` | `1778874.28 ns` | `1271620.56 ns` | `0.715x` | `11/11` | `1.69%/1.83%` |
| `readNumericDocument` | `2491597.20 ns` | `1640251.43 ns` | `0.658x` | `11/11` | `3.31%/3.06%` |
| `writeEscapedStrings` | `448960.56 ns` | `451154.82 ns` | `1.005x` | `5/11` | `2.82%/2.29%` |
| `writeEscapedBytes` | `405649.37 ns` | `411648.00 ns` | `1.015x` | `5/11` | `1.91%/3.86%` |
| `writePlainStrings` | `114671.78 ns` | `113378.18 ns` | `0.989x` | `6/11` | `3.33%/3.69%` |

Native 归档 SHA-256：
`8a580e1d66d3ac44cce81786531517b07603f169b3e3b15b2cd32872b004b54d`。
Native 运行源码闭包 SHA-256 为
`c923cddabb5182faadee9a2756543c1a3bea89afc9f8590e64f2ad515d0a68d9`。

## 4. 决定

```text
Public API mechanical inventory: PASS (1094 declarations; 9 packages)
Public API migration review: PASS (approved-for-release; 17 reviewed deltas)
Local fresh-source simulation: PASS (historical; current source-only candidate covered by hosted registry rehearsal)
Hosted PR execution: NOT RUN for local RSS checkpoint (last historical run 34779604448 passed; rerun required after push)
Seven-library evidence freshness: BLOCKED for local RSS checkpoint (historical run predates RSS sidecars; rerun required)
Three-library performance qualification: BLOCKED (timing passed; peak RSS missing from archive)
Pure baseline/candidate qualification: BLOCKED (timing passed; peak RSS missing from archive)
Native acceleration claim: NON-BLOCKING / NOT QUALIFIED (current diagnostic batch is noisy; no precise acceleration claim)
Hosted main execution and Pages: PASS historically (run 34511955542; not the current candidate or new baseline)
Coverage: PASS historically (previous PR Core Coverage job passed; current RSS checkpoint has no hosted result)
Release decision: BLOCKED; seven-library, three-library and Pure performance qualification lack peak RSS, and merged-main CI/Pages plus final release assets are still pending
```

发布基线固定为 Cangjie STS `1.1.3`（`cjc/cjpm 1.1.3`）。上一个候选曾通过
基础测试、API inventory、Pure/三库 timing gate 和 hosted run
`34779604448` 的 28 个 PR jobs（含当时的 seven-library freshness、CI policy tests、
Coverage、API docs、Windows/macOS Pure 和 package rehearsal）。上一次
registry rehearsal 也在 enforced source-only candidate 上通过；本地 RSS checkpoint
尚未重新执行 hosted jobs。当前性能归档缺少发布检查要求的 peak RSS，因此性能
qualification 尚未闭合。rehearsal 已生成九个临时 `.cjp`，但最终
`manifest.json`、`environment.json`、`checksums.txt` 尚未生成或上传。
候选侧仍有 RSS 性能门禁未闭合，且发布策略要求先合并到 `main`，再等待合并提交的
required workflows 和 Pages 通过；因此当前不能创建 tag、GitHub Release 或执行中心包
仓库发布。
Native noisy 结果不阻断普通 Release，但不能用于精确 acceleration claim；5% target
improvement 只属于明确声明的 optimization mode。

