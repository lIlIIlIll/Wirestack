# 0.1.0 发布证据

本页记录 `0.1.0` 候选的可审计验收状态。每个结果绑定测量提交、源码身份、
SDK、runner、命令和校验和；不把本地结果写成 hosted 结果，也不把诊断性能数据
写成发布资格。

## 1. 冻结身份

| Field | Value |
| --- | --- |
| Planned release identity | `0.1.0` |
| Candidate measured commit | `00eaf70423b0d6497c7f3e30798734ccc2b9b7b3` |
| Candidate tree | `99c007bf4b24d6857091e3c77c9b34b6ed28cdc0` |
| Package manifest | 九个 package，版本均为 `0.1.0` |
| Release graph | `release/release-graph.toml`；status=`release-ready` |
| Evidence updated | `2026-09-11` |
| Local qualification host | Linux Arch `7.2.3-Arch1-3`, x86_64；Intel Core i7-8700 |
| Local qualification SDK | Cangjie `1.1.0-alpha.20260829040003 (cjnative)`；cjpm `1.1.3` |
| Hosted PR SDK | Cangjie STS `1.1.0`；resolution=`pinned-sts` |

本地编译器 `cjc` SHA-256 为
`bc0f32df9c610dcbb05f437552ff57ec6c6e075a54721f46cc9c882a62d2d836`，
`cjpm` SHA-256 为
`b867fca2fd0d4bc19bf195e7872f6f13d5019fd3ba5f409291814f7c5bdfa313`。
首批 Pure 测量使用该工具链。重跑期间固定 SDK 的动态 `stdx` 库路径消失，
因此第二批没有形成完整的可比较报告；没有用后来出现的其他 SDK 替代它。

Hosted PR 为 [#26](https://github.com/lIlIIlIll/yjson/pull/26)，当前候选最新
run 为 [`34563502643`](https://github.com/lIlIIlIll/yjson/actions/runs/34563502643)；
该 run 因 `Seven-library evidence drift` 失败，不能写成 hosted PASS。

## 2. Gate 状态

| Gate | Status | Evidence |
| --- | --- | --- |
| Public API/C ABI mechanical inventory | PASS | `1094` Cangjie declarations；九包 inventory；C ABI delta 全部 `reviewed-for-0.1.0` |
| Public API migration review | PASS | `release/public-cangjie-delta-bfd29.toml` 为 `approved-for-release`；17 个 reviewed delta，native activator removal 与 writer seam 分组独立 |
| Local Linux fresh candidate | **STALE** | 既有 `576/576` rehearsal 绑定更早 commit，不是当前 `00eaf70` 的发布证据 |
| Hosted PR CI | **BLOCKING** | 当前候选 run `34563502643` 因 Seven-library evidence drift 失败 |
| Hosted main CI / Pages | PASS (historical) | run [`34511955542`](https://github.com/lIlIIlIll/yjson/actions/runs/34511955542) 的 28 jobs 与 Pages 通过；它不是当前候选的合并后 run |
| Coverage | PASS (historical) | project line `8508/10345=82.2%`、branch `3722/5262=70.7%`；changed core line/branch 均 `100.0%` |
| Source-only staging | **STALE** | 既有 staging 绑定更早 candidate；当前候选尚未形成最终包 bundle |
| Package rehearsal | **STALE** | 既有九包 bundle 绑定 `fc050734`，未上传，不能代表当前候选 |
| Seven-library matrix | **BLOCKING** | `current-main.json` 仍绑定 `2758853` 与旧 release graph；严格校验报告 current release candidate identity mismatch，当前主机没有可用的 <1% idle-core 窗口完成新矩阵 |
| Three-library release performance | **BLOCKING** | 当前候选完整 36-workload 证据尚未运行 |
| Pure baseline/candidate qualification | **BLOCKING** | 当前候选首批正式结果未通过；规定重跑在第 7 轮因固定 SDK 动态库缺失退出，没有第二批有效资格报告 |
| Native acceleration | **BLOCKING** | 当前候选 Native performance 尚未用固定 SDK 重跑；旧 native performance 绑定 b0，不作为当前候选证据 |
| Release policy | **BLOCKING** | Seven-library、three-library、Pure 和 Native 当前候选证据未全部通过；没有创建 tag 或 Release |
| Annotated tag / GitHub Release | NOT RUN | Release policy remains blocking; no tag, release, or uploaded assets created |
| Central package registry | NOT RUN | 未授权发布；没有执行 central publication |


### 候选资产摘要（未上传）

现有资产 bundle 只绑定旧 commit `fc050734aefa2509d41e5ebb769d47fa7b18f7b6`，
不是当前 `00eaf70423b0d6497c7f3e30798734ccc2b9b7b3` 的发布资产。它保留在本地
作为历史 rehearsal，未上传；当前候选没有在性能门禁通过前生成可发布 bundle。

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

### Pure 基线/候选（当前候选）

当前 runner 已删除与 `packages/benchmarks` 不存在的四个 `yjsonDocument*` case，
保留 24 个实际存在的 case。正式第一批以
`175a4b23656ab44d2d139b810e69ac364347297a` 为 baseline、以当前候选
`00eaf70423b0d6497c7f3e30798734ccc2b9b7b3` 为 candidate，使用 11 轮、CPU 8、
128 MiB、`--gate-mode optimization --target-case yjsonStringDecodeLargeProfileArray`
以及 `--rebuild --enforce`。

第一批目标 `yjsonStringDecodeLargeProfileArray`：baseline `95.784 us`，
candidate `93.943 us`，C/B=`0.981x`，improvement=`1.9%`，candidate wins=`8/11`。
按旧的内部优化目标计算，该行未达到 5% improvement；按现在的策略，5% 是
optimization mode 的可选目标，不是普通 Release 的必要条件。该批目标 CV 为
`5.96%/6.50%`，全表还存在 CV 超过 `5%`、普通回退超过 `1.05x` 的行，
因此同一批数据仍不能通过普通 Release 的稳定性和回退门禁。
`summary.json` SHA-256 为
`67234419929b5293472b89d403513c526b1b895186fd3a6e42e2cad1d30b5d24`，
`provenance.json` SHA-256 为
`c7d7e9e92dde41a42436a1b6e8e1c54859406dcb40cee37837ec96247a51f73e`；
该批原始 gates `passed=false`，命令 exit `1`。

按方法对相同输入执行第二批完整重跑。第二批在第 7 轮的
`decodePersonChunk4k` candidate 进程退出，日志记录
`libstdx.encoding.json.so: cannot open shared object file`，因此没有生成
第二批 `summary.json`，不能将这次中断标记为 noisy 或 PASS。固定的
`1.1.0-alpha.20260829040003` SDK 路径在重跑期间被外部环境移除；没有切换
到后来出现的其他 SDK 继续测量。Pure qualification remains BLOCKING.

### Native acceleration

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
Local fresh-source simulation: STALE (existing 576/576 rehearsal predates 00eaf70)
Hosted PR execution: BLOCKING (run 34576579249 failed Seven-library evidence drift)
Seven-library evidence freshness: BLOCKING (marker identity is stale; no idle-core window for a fresh matrix)
Three-library performance qualification: BLOCKING (current candidate matrix not run)
Pure baseline/candidate qualification: BLOCKING (release-mode stability/regression failure; prescribed rerun aborted by missing fixed SDK library)
Native acceleration: BLOCKING (current candidate performance not revalidated)
Hosted main execution and Pages: PASS historically (run 34511955542; not the current candidate)
Coverage: PASS historically (project 82.2%/70.7%; changed core 100.0%/100.0%)
Release decision: BLOCKED; no tag, GitHub Release, or registry publication
```

当前可执行的下一步是恢复并固定
`1.1.0-alpha.20260829040003` SDK，获得 <1% idle-core 窗口，再按 release mode
重新生成当前候选的七库、三库、Pure 和 Native 证据。Pure 第一批的稳定性和普通回退
仍需处理；5% target improvement 只属于明确声明的 optimization mode，不是普通
Release 的必要条件。不能通过切换 target、筛选 case 或重写历史 metadata 关闭其他门禁。
关闭前不得创建 `0.1.0` tag 或 GitHub Release。
