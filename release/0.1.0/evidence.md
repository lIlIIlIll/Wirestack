# 0.1.0 发布证据

本页记录 `0.1.0` 候选的可审计验收状态。每个结果绑定测量提交、源码身份、
SDK、runner、命令和校验和；不把本地结果写成 hosted 结果，也不把诊断性能数据
写成发布资格。

## 1. 冻结身份

| Field | Value |
| --- | --- |
| Planned release identity | `0.1.0` |
| Candidate measured commit | `533284b9b8e6eee5c65b7fbbc2701ef8f4b35380` |
| Candidate tree | `1becedac11e248c417f8e455c8db230514884d1a` |
| Package manifest | 九个 package，版本均为 `0.1.0` |
| Release graph | `release/release-graph.toml`；status=`release-ready` |
| Evidence updated | `2026-09-11` |
| Local qualification host | Linux Arch `7.2.3-Arch1-3`, x86_64；Intel Core i7-8700 |
| Release qualification SDK | Cangjie STS `1.1.3`；local path `/home/elliot/cangjie_sdk/sts1.1.3`；当前候选已完成可达的本地验证，正式性能门禁仍有阻断 |
| Hosted PR SDK | Cangjie STS `1.1.3`；resolution=`pinned-sts`；run [`34596071836`](https://github.com/lIlIIlIll/yjson/actions/runs/34596071836) 失败于 `Seven-library evidence drift` |

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
| Hosted PR CI | **BLOCKING** | run [`34596071836`](https://github.com/lIlIIlIll/yjson/actions/runs/34596071836) 仅 `Seven-library evidence drift` 与其汇总 job 失败；pinned STS、覆盖率、Windows/macOS Pure 及其余 required jobs 通过 |
| Hosted main CI / Pages | PASS (historical) | run [`34511955542`](https://github.com/lIlIIlIll/yjson/actions/runs/34511955542) 的 28 jobs 与 Pages 通过；它不是 `1.1.3` 基线下当前候选的合并后 run |
| Coverage | PASS (current hosted job) | 当前 PR run 的 `Core Coverage` job 通过；历史 project line `8508/10345=82.2%`、branch `3722/5262=70.7%`，changed core line/branch 均 `100.0%` |
| Source-only staging | PASS | 最新 `scripts/ci_fresh_checkout.sh` 在 STS `1.1.3` 下完成仅源码暂存和发布树复制 |
| Package rehearsal | PASS (fresh) | 当前 qvt fresh checkout 的 `registry-rehearsal` job 通过；未把临时 rehearsal 树当作最终上传 bundle |
| Seven-library matrix | **BLOCKING** | 旧 marker 和结果使用旧工具链/旧 release graph；STS `1.1.3` 下七库 correctness preflight 已完成 `7/7`，但正式完整矩阵因没有 `<1%` idle-core 窗口尚未运行 |
| Three-library release performance | **BLOCKING** | `1.1.3` 基线下当前候选的远端正式 36-workload 三库证据尚未运行；本地 Native 诊断不替代该 gate |
| Pure baseline/candidate qualification | **BLOCKING** | STS `1.1.3` 下已完成显式 CPU 的 24-case、11 轮 release 诊断，但 CPU idle 资格为空且稳定性/回退 gate 未通过，不能写成正式 PASS |
| Native acceleration | **BLOCKING** | STS `1.1.3` 下当前候选已完成 36-workload、11 轮三库测量，但 `0/36` stable、`36/36` noisy，按方法整体不具备发布资格 |
| Release policy | **BLOCKING** | Seven-library、three-library、Pure 和 Native 当前候选证据未全部通过；没有创建 tag 或 Release |
| Annotated tag / GitHub Release | NOT RUN | Release policy remains blocking; no tag, release, or uploaded assets created |
| Central package registry | NOT RUN | 未授权发布；没有执行 central publication |


### 候选资产摘要（未上传）

现有资产 bundle 只绑定旧 commit `fc050734aefa2509d41e5ebb769d47fa7b18f7b6`，
不是当前 `533284b9b8e6eee5c65b7fbbc2701ef8f4b35380` 的发布资产。它保留在本地
作为历史 rehearsal，未上传；当前候选虽已通过 fresh package rehearsal，仍未在性能
门禁通过前生成可发布 bundle。

历史 bundle 的 `checksums.txt` SHA-256 为
`3a2b7cfef4623c97c6aa78ff9751b5c726ef5951bc9e6fd336165e1f0f9d690c`；
其内容和九个 `.cjp` 的摘要不代表当前候选，不能用于 GitHub Release。


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

这些历史数字不能与当前七库报告合并或推导跨主机比例。当前七库矩阵已绑定
`2758853efe1117c7d2b272abd36cf90de46526f5`；三库完整性能资格仍待按当前候选单独完成。

### 三库共同 workload

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
`533284b9b8e6eee5c65b7fbbc2701ef8f4b35380`、tree
`1becedac11e248c417f8e455c8db230514884d1a` 上，以
`175a4b23656ab44d2d139b810e69ac364347297a` 为 baseline，执行了
24 个实际存在的 case、11 轮、128 MiB、`--gate-mode release`、
`--rebuild --enforce`。正式结果使用显式 `--cpu 2`，其
`cpu-selection.json` 为 `sample_seconds=0`、CPU `2/8`、idle
qualification=`null`，因此只是诊断数据，不是 `<1%` idle-core 正式证据。

该批 `summary.json` 的关键 gate 为 `all_ratios_at_most_1_05=false`、
`both_cv_at_most_5_percent=false`、`passed=false`。代表性行包括：
`yjsonStringEncodeDeepNestedProfiles` 回退 `-6.5%`、`parseStringRecords1m`
回退 `-4.3%`；改善行包括 `yjsonStringDecodeLargeInt64Map` `16.4%` 和
`yjsonBytesDecodeLargeInt64Map` `11.3%`。当前批次 summary 记录了完整 24 行，
不把单个改善行写成整体 PASS。

baseline/candidate product source SHA-256 分别为
`df9108e367363847b0fd59b3c611cc6a3504f4d426152e13479caf3e8b94d7f9` 和
`6056f53aa56767a69a29685dad1d6b8fadd8c39a7b47ca6ecc60b46f114acb0b`；
harness=`4d5788b785c9b69993f91e78934dcb5e21fca8b9ac2b2a7c6986c115e65e0865`，
runner=`181b6f12b63e4b2975ddeb8be85072e8f577d8cd8f7870b916b374f4b5e758b1`，
corpus=`db9b0242e01fb4cfa2468245f8be5329a0967052412b7340f12c468c6202a70f`。
`summary.json` SHA-256 为
`c3f8ee88d1d47e574e8b5a3eda83e36714f4ae22e8d971dcf1446510feb6819c`，
`provenance.json` SHA-256 为
`3469131db051f4d37476761273309aad3abf6bc0f77f35835af79d9e0f9db148`，
`cpu-selection.json` SHA-256 为
`45e387ca46ee0da33a6ee02ba3b0aa99d0b488e651d143cce0fca98fb37bc9a5`。
工具链为 `cjc/cjpm 1.1.3`；可用的无 `--cpu` 探针曾观察到 CPU `2/8`
约 `9.13%/9.88%` 和 CPU `4/10` 约 `11.91%/11.92%`，均不满足 `<1%`。

### Native acceleration（当前候选，STS `1.1.3`）

`scripts/json_cjfast_perf_run.py` 在 qvt 候选上使用固定 CPU `4`、128 MiB、
11 轮、完整 36 个 yjson/stdx.json/cjfast_json workload 完成，随后由
`scripts/json_cjfast_perf_summary.py` 汇总。该批三个库均完成 11 轮，但
稳定 workload 为 `0/36`、noisy workload 为 `36/36`；按方法即使若干行方向上
yjson 更快，也不能作为 Native 发布资格。

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
因此该批保留为 STS `1.1.3` 下的当前候选诊断，正式 Native gate 仍为 BLOCKING。

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
Hosted PR execution: BLOCKING (run 34596071836 failed Seven-library evidence drift; pinned STS and other required jobs passed)
Seven-library evidence freshness: BLOCKING (current formal matrix not run; correctness preflight 7/7 is not formal performance evidence)
Three-library performance qualification: BLOCKING (remote formal current-candidate matrix not run)
Pure baseline/candidate qualification: BLOCKING (explicit-CPU diagnostic failed stability/rollback gates and has no idle qualification)
Native acceleration: BLOCKING (current STS 1.1.3 batch has 0/36 stable and 36/36 noisy workloads)
Hosted main execution and Pages: PASS historically (run 34511955542; not the current candidate or new baseline)
Coverage: PASS (current PR Core Coverage job passed; historical thresholds remain recorded above)
Release decision: BLOCKED; no tag, GitHub Release, or registry publication
```

发布基线已从 STS `1.1.0` 迁移到 `/home/elliot/cangjie_sdk/sts1.1.3`
（cjc/cjpm `1.1.3`）。当前候选已通过本地 fresh-checkout 和完整基础测试，
并完成了可达的 STS `1.1.3` 诊断测量；但正式七库矩阵、远端三库矩阵、满足
idle-core 资格的 Pure 证据，以及稳定的 Native 证据仍缺失或未通过。旧
`1.1.0` 结果、marker 和 bundle 不能复用；5% target improvement 仍只属于明确
声明的 optimization mode。关闭这些门禁前不得创建 `0.1.0` tag 或 GitHub Release。

