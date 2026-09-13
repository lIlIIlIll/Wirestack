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
| Release qualification SDK | Cangjie STS `1.1.3`；正式七库和 Pure 测量均记录 `cjc/cjpm 1.1.3` |
| Hosted PR SDK | Cangjie STS `1.1.3`；resolution=`pinned-sts`；run [`34710721196`](https://github.com/lIlIIlIll/yjson/actions/runs/34710721196) 失败于 `Seven-library evidence drift` |


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
| Local Linux fresh candidate | PASS | `scripts/ci_fresh_checkout.sh` 在 qvt 候选、STS `1.1.3` 下通过；release tree `292` files，包含 API、cjdoc、九包 rehearsal、Native、sanitizer 和 fuzz-short jobs |
| Hosted PR CI | **BLOCKING** | run [`34710721196`](https://github.com/lIlIIlIll/yjson/actions/runs/34710721196) 仅 `Seven-library evidence drift` 与其汇总 job 失败；pinned STS、覆盖率、Windows/macOS Pure 及其余 required jobs 通过 |
| Hosted main CI / Pages | PASS (historical) | run [`34511955542`](https://github.com/lIlIIlIll/yjson/actions/runs/34511955542) 的 28 jobs 与 Pages 通过；它不是 `1.1.3` 基线下当前候选的合并后 run |
| Coverage | PASS (current hosted job) | 当前 PR run 的 `Core Coverage` job 通过；历史 project line `8508/10345=82.2%`、branch `3722/5262=70.7%`，changed core line/branch 均 `100.0%` |
| Source-only staging | PASS | 最新 `scripts/ci_fresh_checkout.sh` 在 STS `1.1.3` 下完成仅源码暂存和发布树复制 |
| Package rehearsal | PASS (fresh) | 当前 qvt fresh checkout 的 `registry-rehearsal` job 通过；未把临时 rehearsal 树当作最终上传 bundle |
| Seven-library matrix | **PASS (local evidence pending clean-check verification)** | 当前提交绑定的两批 STS `1.1.3` 归档各含 770/770 单元，均完成 CPU 1/sibling 49 idle sample；完整性校验通过，结果页记录 0/10 stable、10/10 noisy |
| Three-library release performance | **BLOCKING** | 当前候选的 STS `1.1.3` 远端正式 36-workload 三库矩阵正在运行，结果尚未归档；本地诊断不替代该 gate |
| Pure baseline/candidate qualification | **PASS** | [当前 Pure 结果](../../docs/performance/results/2026-09-13-linux-release-pure.md)绑定当前候选，STS `1.1.3` 下 24 case、11 轮、release gate `all_ratios_at_most_1_05=true`；noisy 只限制精确性能声明 |
| Native acceleration | NON-BLOCKING (claim not qualified) | 当前候选的 Native/三库诊断为 `0/36` stable、`36/36` noisy；噪声只阻止精确 Native/跨库性能声明，不阻断普通 Release |
| Release policy | **BLOCKING** | Hosted PR CI 仍失败，当前三库正式证据尚未归档；Native noisy 数据本身不是阻断项，没有创建 tag 或 Release |
| Annotated tag / GitHub Release | NOT RUN | Release policy remains blocking; no tag, release, or uploaded assets created |
| Central package registry | NOT RUN | 未授权发布；没有执行 central publication |


### 候选资产摘要（未上传）

当前候选的性能复核资料已分别保存在：

- `benchmarks/results/full-seven-library/2026-09-13-release-4766daa/`：两批七库 raw archive、脚本闭包、身份和 checksum；
- `benchmarks/results/release-performance/2026-09-13-4766daa/yjson-pure-release-4766daa-r4.tar.gz`：Pure 24-case raw archive。

这些是仓库中的可审计证据，不是 GitHub Release 上传资产。当前候选的九个 `.cjp`、
`manifest.json`、`environment.json` 和最终 `checksums.txt` 尚未生成；因此不能把上述
性能归档当作已发布 bundle。

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
`benchmarks/results/full-seven-library/2026-09-13-release-4766daa/`，严格 freshness
校验将在证据文件提交后对 clean checkout 执行。

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

### Pure 基线/候选（当前候选，STS `1.1.3`）

正式 runner `scripts/json_pure_perf_compare.py` 在当前候选
`4766daa7ac88a5ad0869cfa2dbdb12c63acd0161`、tree
`ccbee2fa194180c66374d44852c0122c30b7e9a6` 上，以
`175a4b23656ab44d2d139b810e69ac364347297a` 为 baseline，执行 24 个实际
case、11 轮、128 MiB、`--gate-mode release`、`--rebuild --enforce`。CPU 1
与 sibling 49 的 30 秒 idle sample 均为 `0.0%`。

`summary.json` 的关键 gate 为 `all_ratios_at_most_1_05=true`、`passed=true`；
`both_cv_at_most_5_percent=false` 只表示部分行 noisy，按 Release policy 不阻断普通
Release。最大回退为 `yjsonStringEncodePerson` 的 `-3.77%`（ratio `1.038x`），
最大改善为 `yjsonBytesDecodeLargeInt64Map` 的 `24.26%`（ratio `0.757x`）。

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
Local fresh-source simulation: PASS (qvt; STS 1.1.3; fresh checkout jobs passed)
Hosted PR execution: BLOCKING (run 34710721196 failed Seven-library evidence drift; pinned STS and other required jobs passed)
Seven-library evidence freshness: PENDING FINAL CLEAN-CHECK (current candidate archives and identity are refreshed; strict checker runs after the evidence commit)
Three-library performance qualification: BLOCKING (remote formal current-candidate matrix is still running)
Pure baseline/candidate qualification: PASS (STS 1.1.3; 24 cases; 11 rounds; release ratios all at most 1.05)
Native acceleration claim: NON-BLOCKING / NOT QUALIFIED (current diagnostic batch is noisy; no precise acceleration claim)
Hosted main execution and Pages: PASS historically (run 34511955542; not the current candidate or new baseline)
Coverage: PASS (current PR Core Coverage job passed; historical thresholds remain recorded above)
Release decision: BLOCKED; no tag, GitHub Release, or registry publication
```

发布基线固定为 Cangjie STS `1.1.3`（`cjc/cjpm 1.1.3`）。当前候选已通过本地
fresh-checkout、基础测试、API inventory 和 Pure 普通 Release gate；正式七库证据已
按当前候选重新归档，严格 freshness 结果待证据提交后执行。远端三库正式矩阵仍在运行，
Hosted PR run `34710721196` 仍失败，因此合并后的 `main` 工作流、tag、GitHub Release
和中心包仓库发布都不能执行。Native noisy 结果不阻断普通 Release，但不能用于精确
acceleration claim；5% target improvement 只属于明确声明的 optimization mode。

