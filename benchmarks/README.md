# Comparison benchmarks

本目录提供 yjson、`stdx.encoding.json`、`cjfast_json` 与 Java fastjson2 的 adapter；
`scripts/json_perf_baseline.py` 将各 runner 的输出归一化为同一 CSV/Markdown schema。

2026-08-22 的纯 Go `dwisiswant0/yyjson` DOM 对比是独立受控实验，当前没有集成到这个
baseline runner，也没有把 Go adapter 提交到本目录。结果、API 边界和现有 artifact 状态见
[Go yyjson result](../docs/performance/results/2026-08-22-go-yyjson.md)。

它是开发用 baseline runner，不会自动复现 `docs/performance.md` 中所有受控 Server
实验。脚本默认的三组 runner 不是一个共享 runtime，未固定 CPU、host load、JDK/SDK
时也不能当作同步四库排名。

## 目录

- `packages/benchmarks/`：yjson 与 stdx.json 的 Cangjie benchmark cases。
- `cjfast_json/`：把 adapter 注入 pinned cjfast_json checkout。
- `java_fastjson2/`：独立 fastjson2 Java harness。
- `scripts/json_perf_baseline.py`：运行或读取三种输出，生成统一结果。

## 环境依赖

- Cangjie SDK 1.1，`cjc` 与 `cjpm` 可用；
- 与当前 SDK 匹配的动态 stdx，以及 cjfast adapter 需要的静态 stdx JSON FFI archives；
- Python 3；
- 对 Java 比较：`javac`、`java` 与 fastjson2 2.0.52 jar；
- 对 cjfast_json：本地 checkout，或允许脚本从 GitCode clone pinned revision
  `eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65`。

fastjson2 jar 不在仓库内。通过 `FASTJSON2_JAR=/absolute/path/fastjson2-2.0.52.jar`
指定；不要依赖 runner 脚本中的开发机 fallback path。

## 最短运行

从仓库根目录执行：

```bash
scripts/json_perf_baseline.py --quick \
  --cjfast-dir /absolute/path/to/cjfast_json \
  --out-dir target/perf-baseline
```

默认 Cangjie 命令是：

```bash
cd packages/benchmarks
../../scripts/codex_cangjie_env cjpm bench --no-color --filter ComprehensiveJsonCompareBenchmarks
```

常用选项：

| 选项 | 用途 |
| --- | --- |
| `--skip-cangjie/java/cjfast` | 只运行选定 adapter |
| `--cangjie-output FILE` | 解析已有 Cangjie log |
| `--java-csv FILE` | 解析已有 Java CSV |
| `--cjfast-output FILE` | 解析已有 cjfast log |
| `--cangjie-cmd CMD` | 覆盖 Cangjie benchmark 命令 |
| `--java-arg ARG` | 传给 Java runner，可重复 |
| `--out-dir DIR` | 输出位置 |

Java harness 默认每项 10,000 iterations、3 warmup batches、11 measurement
batches；`--quick` 改为 1,000/1/3。可以传递显式参数：

```bash
scripts/json_perf_baseline.py \
  --java-arg=--iterations --java-arg=10000 \
  --java-arg=--warmup --java-arg=3 \
  --java-arg=--batches --java-arg=11
```

## 输出

默认写入 `target/perf-baseline/`：

- `cangjie_bench.log`；
- `cjfast_json_bench.log`；
- `java_fastjson2.csv` 与 stderr log；
- `json_perf_baseline.csv`：normalized machine-readable rows；
- `json_perf_baseline.md`：按 workload 合并的透视表。

`relative_to_yjson` 是“其他库耗时 / yjson 耗时”。小于 1 表示该对比库在该行更快，
不是 yjson 的 speedup。

## 受控测量要求

准备公开结论时，至少记录 commit SHA、SDK/JDK、构建参数、CPU 型号与 affinity、host
load、warmup、batch 数、原始 log 和输出 checksum。baseline 与 candidate 应在同一台机器
交替执行，并检查 paired direction、p95、CV 与 MAD；本脚本本身不会完成 CPU pinning、
host isolation 或这些统计判定。

完整方法和当前实验边界见 [Performance methodology](../docs/performance/methodology.md)，
实验记录见 [research log](../docs/performance.md)。当前仓库没有提交所有历史 Server raw
reports；文档中只指向 ignored/机器本地路径的结果不能视为外部可审计 artifact。
