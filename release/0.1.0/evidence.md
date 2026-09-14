# 0.1.0 发布证据

本页记录 `0.1.0` 候选的可审计验收状态。每个结果绑定测量提交、源码身份、
SDK、runner、命令和校验和；不把本地结果写成 hosted 结果，也不把诊断性能数据
写成发布资格。

## 1. 冻结身份

| Field | Value |
| --- | --- |
| Planned release identity | `0.1.0` |
| Candidate measured commit | `7436598b6cd22084ea990832b07d972aeae26e1b` |
| Candidate measured tree | `00d9629474c5b5a850bc427aca6f84046dc7ffd5` |
| Package manifest | 九个 package，版本均为 `0.1.0` |
| Release graph | `release/release-graph.toml`；status=`release-ready` |
| Evidence updated | `2026-09-14` |
| Formal performance runner | `Server`；Linux x86_64；七库/三库使用 CPU 3，sibling 51 |
| Release qualification SDK | Cangjie STS `1.1.3`；正式七库、三库和 Pure 测量均记录 `cjc/cjpm 1.1.3` |
| Hosted PR SDK | Cangjie STS `1.1.3`；resolution=`pinned-sts`；历史 candidate run [`34778796451`](https://github.com/lIlIIlIll/yjson/actions/runs/34778796451) 的 28 jobs 全部通过，但早于当前 RSS/API-doc checkpoint |


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
| Local Linux fresh candidate | PASS (historical) | `scripts/ci_fresh_checkout.sh` 的 qvt/STS `1.1.3` 结果曾通过；当时 release tree 为 `292` files，早于当前 `302` 项 manifest；当前候选仍需 hosted fresh-candidate 覆盖 source-only、registry rehearsal 和 freshness |
| Hosted PR CI | **NOT RUN (current RSS/API-doc checkpoint)** | 当前 checkpoint 尚未 push；历史 candidate run 的 28 jobs 全部通过，但早于本地 RSS instrumentation 和吸收的 PR28 API 文档门禁修复；push 后必须重新运行 |
| Hosted main CI / Pages | PASS (historical) | run [`34511955542`](https://github.com/lIlIIlIll/yjson/actions/runs/34511955542) 的 28 jobs 与 Pages 通过；它不是 `1.1.3` 基线下当前候选的合并后 run |
| Coverage | PASS (historical) | 上一次候选 run 的 `Core Coverage` job 通过；历史 project line `8508/10345=82.2%`、branch `3722/5262=70.7%`，changed core line/branch 均 `100.0%` |
| Source-only staging | PASS (historical) | 上一次候选 run 的 `registry-rehearsal` 在 enforced source-only candidate 上通过；当前 RSS/API-doc checkpoint 尚未执行 hosted fresh-candidate |
| Package rehearsal | PASS (historical) | 上一次候选 run 的 `registry-rehearsal` job 通过；当前 RSS/API-doc checkpoint 尚未执行 hosted rehearsal |
| Seven-library matrix | **PASS (RSS-complete)** | 当前候选两批 STS `1.1.3` 归档各含 770/770 单元；CPU 3/sibling 51 idle sample、checksum、identity、summary 和 770 个 RSS sidecar 均通过，见 `benchmarks/results/full-seven-library/2026-09-14-release-7436598/` |
| Three-library release performance | **PASS (RSS-complete)** | 当前候选 STS `1.1.3` 远端正式 36-workload 三库矩阵完成 11 轮；1/36 stable、35/36 noisy，构建与 timed sample 分离，完整 raw archive 与每个进程 peak RSS 均保留；archive SHA-256 为 `c3e3dca387bd4869c1f183fef000427dce95cb5433b07c97510a86dd69ffd490` |
| Pure baseline/candidate qualification | **PASS (RSS-complete)** | 当前候选 STS `1.1.3` 下 24 case、11 轮，`all_ratios_at_most_1_05=true`、`passed=true`；每个进程 peak RSS 均保留；archive SHA-256 为 `4c8c28bd4822ee5d3d0937df2f47f1f0f88bc378c94564ec46560db86edd9cb3` |
| Native acceleration | NON-BLOCKING (claim not qualified) | 当前三库结果为 `1/36` stable、`35/36` noisy；该结果不支持本次发布的精确 Native/跨库 acceleration claim，且 noisy 本身不阻断普通 Release |
| Release policy | **BLOCKING** | 当前三类性能证据已完成 RSS qualification，但仍要求当前候选 hosted CI、合并到 `main`、合并后 required workflows/Pages 通过；当前没有创建 tag 或 Release |
| Annotated tag / GitHub Release | NOT RUN | Release policy remains blocking; no tag, release, or uploaded assets created |
| Central package registry | NOT RUN | 未授权发布；没有执行 central publication |


### 候选资产摘要（未上传）

当前候选的性能复核资料已分别保存在：

- `benchmarks/results/full-seven-library/2026-09-14-release-7436598/`：两批 RSS-complete 七库 raw archive、sidecar、脚本闭包、身份和 checksum；
- `benchmarks/results/release-performance/2026-09-14-7436598/yjson-pure-release-7436598-r1.tar.gz`：Pure 24-case RSS-complete raw archive，SHA-256 为 `4c8c28bd4822ee5d3d0937df2f47f1f0f88bc378c94564ec46560db86edd9cb3`；
- `benchmarks/results/release-performance/2026-09-14-774e89e/yjson-three-library-release-774e89e-r1.tar.gz`：修正 exact-case filter、build-only RSS 后的三库 36-workload RSS-complete raw archive，SHA-256 为 `c3e3dca387bd4869c1f183fef000427dce95cb5433b07c97510a86dd69ffd490`；

这些是仓库中的可审计证据，不是 GitHub Release 上传资产。七库证据目录另以
`checksums.txt` 绑定 formal archive、harness source、json4cj source、overlay 记录和
`source-identity.json`。包仓库 rehearsal 已在
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
该行及其他 noisy 行只保留方向证据，不发布精确比例；由于第二批仍未满足 CV 门槛，三库正式性能 gate 为 BLOCKING。

### 当前：三库共同 workload（STS `1.1.3`）

正式 runner `scripts/release_performance_compare.sh` 在 `Server` 的
`ubuntu2223131`、Linux x86_64、CPU 3、128 MiB 堆上执行 runner/source-stage 提交
`774e89e577028b2daf2632c965ee35ebe49b10b4`。每个
yjson/stdx.json/cjfast_json 共同 workload 完成 11 轮，workload 顺序逐轮旋转、
偶数轮反转，三库顺序逐轮旋转；36/36 workload 完整收集，没有删除 noisy 行。

- Stable：`1/36`；noisy：`35/36`（三库各自 CV 均纳入 stable/noisy 判断）。
- runner 为每个库传入 `suite.source_case` 的精确 filter；summary 只汇总 CSV 中
  `Case == manifest.source_case` 的行，不会混入同前缀的 `*BatchGuard` 等额外 case。
- Cangjie STS `1.1.3`；`cjc/cjpm` 版本和环境、每轮 raw report 与每个进程 peak RSS
  sidecar 均在归档中；metadata 的 `sdk_label` 保留为 runner 原值 `unknown`。
- 两个 Cangjie benchmark package 先用 `cjpm bench --no-run --no-color` 构建；
  timed sample 只执行 `cjpm bench --skip-build`。构建日志未纳入 RSS 计时。
- `cjfast_json_commit=eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65`。
- RSS sidecar 使用 GNU `/usr/bin/time -v`，summary 记录的最大 timed process RSS 为
  `339188 kbytes`。
- raw archive：
  `benchmarks/results/release-performance/2026-09-14-774e89e/yjson-three-library-release-774e89e-r1.tar.gz`
  ；SHA-256 为 `c3e3dca387bd4869c1f183fef000427dce95cb5433b07c97510a86dd69ffd490`。

完整 36 行、summary、manifest、metadata、preflight、RSS sidecar 和复核命令见
[当前三库结果](../../docs/performance/results/2026-09-13-release-three-library.md)。
35 行 noisy 只作为方向和复核数据，不发布稳定的精确跨库排名；timing、RSS 和完整性检查
均通过，当前三库结果已满足本项性能证据的采集要求。

### Pure 基线/候选（当前候选，STS `1.1.3`）

正式 runner `scripts/json_pure_perf_compare.py` 在当前候选
`7436598b6cd22084ea990832b07d972aeae26e1b`、tree
`00d9629474c5b5a850bc427aca6f84046dc7ffd5` 上，以
`175a4b23656ab44d2d139b810e69ac364347297a`、tree
`c7116cc24173d8553d4ccce4d31ec80a570b74ee` 为 baseline，执行 24 个实际
case、11 轮、128 MiB、`--gate-mode release`、`--rebuild --enforce`。CPU 2
与 sibling 50 的 30 秒 idle sample 均为 `0.0%`。

`summary.json` 的 timing gate 为 `all_ratios_at_most_1_05=true`、`passed=true`；
`both_cv_at_most_5_percent=false` 只表示部分行 noisy，按普通 Release 的 timing policy
不阻断回退检查。最大回退为 `yjsonBytesDecodeProfileBundle` 的 `-4.7%`（ratio
`1.047x`），最大改善为 `yjsonStringDecodeProfileBundle` 的 `40.6%`（ratio `0.594x`）。
GNU `/usr/bin/time -v` 已为 24 × 11 × 2 个进程记录 peak RSS，summary 和 sidecar
均完成校验。

完整 24 行、命令、环境和身份见
[当前 Pure 结果](../../docs/performance/results/2026-09-13-linux-release-pure.md)；
RSS-complete raw archive 为
`benchmarks/results/release-performance/2026-09-14-7436598/yjson-pure-release-7436598-r1.tar.gz`，
SHA-256 为 `4c8c28bd4822ee5d3d0937df2f47f1f0f88bc378c94564ec46560db86edd9cb3`。

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
Local fresh-source simulation: PASS (historical; current source-only candidate still needs hosted registry rehearsal)
Hosted PR execution: NOT RUN for current RSS/API-doc checkpoint (rerun required after push)
Seven-library evidence freshness: PASS (two 770/770 RSS-complete archives; current marker schema v2)
Three-library performance qualification: PASS (36/36 workloads; 11 rounds; 1 stable / 35 noisy; exact-case and RSS-complete archive)
Pure baseline/candidate qualification: PASS (24 cases; 11 rounds; release ratio gate and RSS-complete archive)
Native acceleration claim: NON-BLOCKING / NOT QUALIFIED (current three-library batch has 1 stable and 35 noisy workloads; no precise acceleration claim)
Hosted main execution and Pages: PASS historically (run 34511955542; not the current candidate or new baseline)
Coverage: PASS historically (previous PR Core Coverage job passed; current checkpoint has no hosted result)
Release decision: BLOCKED; current hosted PR CI, merge to main, post-merge workflows/Pages, and final release assets are still pending
```

发布基线固定为 Cangjie STS `1.1.3`（`cjc/cjpm 1.1.3`）。当前候选的七库、三库和
Pure 证据已在合格 `Server` 上使用 GNU `/usr/bin/time -v` 完成 peak RSS 采集，并在
归档、sidecar、summary 和 checksum 中闭合。历史 hosted run `34779604448` 的 28 个
PR jobs 早于当前 RSS/API-doc checkpoint；当前候选 push 后必须重新执行 hosted jobs。
rehearsal 已生成九个临时 `.cjp`，但最终 `manifest.json`、`environment.json`、
`checksums.txt` 尚未生成或上传。
发布策略仍要求先合并到 `main`，再等待合并提交的 required workflows 和 Pages 通过；
因此当前不能创建 tag、GitHub Release 或执行中心包仓库发布。
Native noisy 结果不阻断普通 Release，但不能用于精确 acceleration claim；5% target
improvement 只属于明确声明的 optimization mode。

