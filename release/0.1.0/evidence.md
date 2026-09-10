# 0.1.0 发布证据

本页记录 `0.1.0` 候选的可审计验收状态。每个结果绑定测量提交、源码身份、
SDK、runner、命令和校验和；不把本地结果写成 hosted 结果，也不把诊断性能数据
写成发布资格。

## 1. 冻结身份

| Field | Value |
| --- | --- |
| Planned release identity | `0.1.0` |
| Candidate measured commit | `2758853efe1117c7d2b272abd36cf90de46526f5` |
| Candidate tree | `120f0db3b2668cf2ebb2229adbaa5ea758ca50a6` |
| Package manifest | 九个 package，版本均为 `0.1.0` |
| Release graph | `release/release-graph.toml`；status=`migration` |
| Evidence updated | `2026-09-10` |
| Local qualification host | Linux Arch `7.2.3-Arch1-3`, x86_64；Intel Core i7-8700 |
| Local qualification SDK | Cangjie `1.1.0-alpha.20260829040003 (cjnative)`；cjpm `1.1.3` |
| Hosted PR SDK | `1.3.0-alpha.20260829010011`；resolution=`pinned-known-good` |

本地编译器 `cjc` SHA-256 为
`bc0f32df9c610dcbb05f437552ff57ec6c6e075a54721f46cc9c882a62d2d836`，
`cjpm` SHA-256 为
`b867fca2fd0d4bc19bf195e7872f6f13d5019fd3ba5f409291814f7c5bdfa313`。
本地工具链为 `/home/elliot/cangjie_sdk/daily/cangjie`，clang=`22.1.8`，
gcc=`16.2.1`。
Hosted PR 为 [#20](https://github.com/lIlIIlIll/yjson/pull/20)，最新完整
run 为 [`34494604326`](https://github.com/lIlIIlIll/yjson/actions/runs/34494604326)；
run conclusion=`success`。

## 2. Gate 状态

| Gate | Status | Evidence |
| --- | --- | --- |
| Public API/C ABI mechanical inventory | PASS | `1094` Cangjie declarations；九包 inventory；C ABI delta 全部 `reviewed-for-0.1.0` |
| Public API migration review | **BLOCKING** | `release/public-cangjie-delta-bfd29.toml` 仍有 `pending-migration-review` 组；发布图仍为 `migration` |
| Local Linux fresh candidate | PASS | 当前候选的本地 registry rehearsal 完成；`576/576` root tests，九包暂存、构建和 consumer 检查通过 |
| Hosted PR CI | PASS | run `34494604326` conclusion=`success`；Seven-library evidence drift、registry rehearsal、Pure Windows/macOS、Coverage 和 CI Required 均通过 |
| Hosted main CI / Pages | PASS | run [`34506441534`](https://github.com/lIlIIlIll/yjson/actions/runs/34506441534) passed all 28 jobs; [`Deploy API Documentation`](https://github.com/lIlIIlIll/yjson/actions/runs/34506441534/job/102972446294) completed its `Deploy GitHub Pages` step; site [`liliilill.github.io/yjson`](https://liliilill.github.io/yjson/); `github-pages` artifact digest `sha256:a454b4519cc9cf5e311e301035681a18324ce73811dd3e5c2e7d1cf74b9ddbfa` |
| Coverage | PASS | project line `8508/10345=82.2%`、branch `3722/5262=70.7%`；changed core line `26/26=100.0%`、branch `16/16=100.0%`；hosted Core Coverage 成功 |
| Source-only staging | PASS | `stage_source_tree` 复制 `358` 个文件并通过 `--check`；`release_temp_tree --enforce-clean` 复制 `290` 个文件并通过 |
| Package rehearsal | PASS | 九包独立暂存、构建、registry-style consumer 和导出检查成功；最终 release assets 尚未生成 |
| Seven-library matrix | PASS (candidate) / MAIN RECHECK PASS | `current-main.json` binds `2758853`; two batches are `770/770` complete, candidate strict validation passes, and post-merge main run `34506441534` passes after squash-safe closure validation |
| Three-library release performance | **BLOCKING** | 旧 b0 两批仍为 noisy；当前候选的完整 36-workload 证据尚未按当前提交重跑 |
| Pure baseline/candidate qualification | **BLOCKING** | 正式 runner 的四个 `yjsonDocument*` case 与当前 benchmark 源码漂移；target-only A/B 仍因 CV 超过 5% 而 exit `1`，不能作资格证据 |
| Native acceleration | PASS (functional) / REVALIDATE (performance) | 当前 fresh custom-native 通过；旧 native performance 资格绑定 b0，不作为当前候选的性能证据 |
| Release policy | **BLOCKING** | API migration review and current-candidate three-library/Pure/native performance evidence remain incomplete; hosted main workflow and Pages are now PASS |
| Annotated tag / GitHub Release | NOT RUN | Release policy remains blocking; no tag, release, or uploaded assets created |
| Central package registry | NOT RUN | 未授权发布；没有执行 central publication |

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

### Pure 基线/候选

`json_pure_perf_compare.py` 的默认 case 列表包含当前
`packages/benchmarks` 中不存在的四个 `yjsonDocument*` 方法，因此完整命令
无法形成合法的全量报告。以性能父提交
`9d4387192296ce7c3ec5a5024e52ad0084bf7891` 为 baseline、b0 为 candidate，
保留其余 24 个可用 case 后运行 11 轮、CPU 8、128 MiB、`--rebuild --enforce`；
结果归档 SHA-256 为
`fe10c2a302e728015284be0ef67ac648c6cb3abd64fada4a397080289f7e76ac`，
命令 exit `1`。

目标 `yjsonStringDecodeLargeProfileArray`：baseline `74.633 us`，candidate
`75.182 us`，C/B=`1.007x`，improvement=`-0.7%`，candidate wins=`2/11`；
目标要求为提升至少 `5%` 且 wins 至少 `5/11`。另有 case 的 CV 超过 `5%`，
因此该 A/B 结果不能作为发布资格。

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
Local fresh-source simulation: PASS (current candidate branch; 576/576 root tests)
Hosted PR execution: PASS (run 34494604326; all 28 jobs passed)
Seven-library evidence integrity/freshness: PASS on candidate branch (two complete 770-cell batches)
Three-library performance qualification: BLOCKING (full current-candidate matrix not run)
Pure baseline/candidate qualification: BLOCKING (runner drift and noisy target-only A/B)
Native acceleration: PASS functionally; performance qualification must be revalidated
Public API migration review: BLOCKING
Hosted main execution and Pages: PASS (run 34506441534; all 28 jobs passed)
Coverage: PASS (project 82.2%/70.7%; changed core 100.0%/100.0%)
Release decision: BLOCKED; no tag, GitHub Release, or registry publication
```

待关闭项：完成新增 native writer declarations 的 migration review；按当前候选
重新生成并通过完整三库/Pure/native 性能与稳定性证据。关闭前不得创建 `0.1.0` tag
或 GitHub Release。
