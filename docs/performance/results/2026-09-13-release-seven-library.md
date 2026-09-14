# 2026-09-14 当前 `0.1.0` 候选七库完整对比

本页记录 [`current-main.json`](../../../benchmarks/results/full-seven-library/current-main.json) 指向的 RSS-complete typed JSON benchmark。两批测量均绑定到提交 `4c2432c80688581dd28afa8bc4a7ec0bdf4858cf`，对应当前 `0.1.0` release candidate 的 measured tree。完整原始证据、RSS sidecar、脚本和 checksum 见[证据目录](../../../benchmarks/results/full-seven-library/2026-09-14-release-4c2432c/README.md)。

每个 workload-library 组合运行 11 个独立进程轮次。每个进程由 GNU `/usr/bin/time -v` 记录 peak RSS，`manifest.csv` 的 `max_rss_kb` 与 sidecar 逐项对应；下表 timing 单位为 µs/op，数值是 11 个轮次的中位数，越小越好。CV 超过 5% 的行标记为 noisy，不发布稳定的跨库精确排名。Cangjie timing 使用构建后的 benchmark executable，GNU time 不包围构建步骤。

## 先看 workload

Encode 从已经构造好的 typed value 生成紧凑 JSON 字符串。Decode 从 canonical JSON 字符串恢复相同的 typed 类型。表中的 payload bytes 是 decode 输入的 UTF-8 大小。

| Workload | Typed value 的形状 | 规模 | Payload bytes |
| --- | --- | ---: | ---: |
| Address | `Address{street_name: String, zipcode: Int64}` | 2 个字段 | 47 |
| Person | 3 个字符串 tag、2 个整数 score、嵌套 Address 和 null nick | 7 个 JSON 字段 | 176 |
| Large Array | `ArrayList<ProfileRecord>`；每条记录有 id、alias 和 level | 64 条记录 | 3929 |
| Large Map | `HashMap<String, Int64>`；key 为 `metric_0` 到 `metric_63` | 64 个 entry | 1013 |
| Deep Nested | `ArrayList<HashMap<String, ArrayList<ProfileRecord>>>` | 8 组 × 4 条记录，共 32 条 | 1929 |

## 结果状态

`Max CV` 是该 workload 在七个库中的最大 CV。只有 `Max CV <= 5%` 的行才是 stable；CV 超过 5% 的行仍完整保留，noisy 本身不改变普通 Release 的回退门禁。

| 批次 | 完整测量单元 | Stable workloads | 结论 |
| --- | ---: | ---: | --- |
| 第一批 | 770/770 | 1/10 | 完整测量；9/10 noisy |
| 第二批 | 770/770 | 2/10 | 完整测量；8/10 noisy |

## 第一批

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 | Max CV |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 0.846 | 2.022 | 3.261 | 3.461 | 2.446 | 0.181 | 0.066 | 30.09% |
| Address decode | 1.240 | 2.219 | 3.318 | 3.438 | 2.031 | 0.319 | 0.072 | 14.61% |
| Person encode | 1.547 | 10.237 | 16.542 | 5.429 | 9.857 | 0.561 | 0.266 | 13.75% |
| Person decode | 7.981 | 19.399 | 28.532 | 20.573 | 15.280 | 1.113 | 0.419 | 6.63% |
| Large Array encode | 26.260 | 84.736 | 249.899 | 91.296 | 75.648 | 8.845 | 4.135 | 7.62% |
| Large Array decode | 82.688 | 173.429 | 394.305 | 173.312 | 77.312 | 18.917 | 5.103 | 8.84% |
| Large Map encode | 6.756 | 124.020 | 180.559 | 128.633 | 128.661 | 1.770 | 1.728 | 5.05% |
| Large Map decode | 26.820 | 241.664 | 350.976 | 222.720 | 223.854 | 5.328 | 3.981 | 7.28% |
| Deep Nested encode | 43.448 | 75.392 | 171.136 | 84.704 | 73.779 | 4.474 | 2.461 | 4.90% |
| Deep Nested decode | 327.040 | 154.700 | 255.093 | 143.104 | 95.275 | 10.423 | 3.409 | 9.02% |

## 第二批

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 | Max CV |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 0.801 | 2.023 | 3.108 | 3.473 | 2.447 | 0.179 | 0.066 | 23.99% |
| Address decode | 1.241 | 2.356 | 3.223 | 3.447 | 2.028 | 0.319 | 0.074 | 16.87% |
| Person encode | 1.549 | 11.125 | 16.902 | 5.444 | 10.085 | 0.562 | 0.270 | 9.71% |
| Person decode | 8.098 | 19.336 | 27.586 | 20.296 | 15.338 | 1.104 | 0.420 | 6.63% |
| Large Array encode | 26.216 | 84.992 | 249.888 | 91.959 | 75.776 | 8.862 | 4.171 | 8.99% |
| Large Array decode | 90.876 | 168.862 | 405.865 | 174.029 | 77.425 | 19.045 | 5.146 | 9.63% |
| Large Map encode | 6.753 | 123.520 | 180.715 | 130.397 | 128.908 | 1.729 | 1.731 | 6.53% |
| Large Map decode | 26.768 | 243.456 | 352.000 | 223.573 | 230.724 | 5.327 | 4.000 | 4.96% |
| Deep Nested encode | 43.421 | 74.496 | 172.000 | 85.248 | 73.728 | 4.437 | 2.484 | 2.96% |
| Deep Nested decode | 328.640 | 154.403 | 271.096 | 142.912 | 95.492 | 10.418 | 3.421 | 9.54% |

## API、环境和解释

每个 adapter 使用语义等价的最快公开 typed API；存在 direct typed path 时不使用 DOM fallback。七库顺序和 workload 顺序逐轮旋转，偶数轮反转 workload 顺序。Cangjie 使用 200 ms warmup、至少 1 秒测量和至少 12 个 batch；Java 每个外层轮次使用一个 fork、3 × 500 ms warmup 和 1 × 1 秒测量。每个 raw manifest 单元同时保留 timing report、日志和 RSS sidecar；构建步骤在未计时的 `cjpm bench --no-run` 阶段完成。

| 项目 | 值 |
| --- | --- |
| Candidate | `4c2432c80688581dd28afa8bc4a7ec0bdf4858cf` |
| Measured tree | `acd6a52d23a96dfc8c8abb4e20ebfacdc1e5cbbe` |
| Product source SHA-256 | `b0120df219570213b3a61a7876349efeabd2bb9bf92a8fb4eea3066e25d11edf` |
| Effective harness SHA-256 | `4d5788b785c9b69993f91e78934dcb5e21fca8b9ac2b2a7c6986c115e65e0865` |
| Candidate identity SHA-256 | `00bfbb6e4929e2152c44c96b08177c18bf2705001557d741fe3cb410b08238be` |
| SDK | Cangjie STS `1.1.3`; `cjc`/`cjpm` `1.1.3` |
| Host | `ubuntu2223131`; Linux 5.15.0-187-generic; x86_64; 96 logical CPUs |
| CPU | CPU 3, sibling 51；两线程 30 秒 idle sample 均低于 1% |
| Heap | `128MB` |
| GNU time | `/usr/bin/time`; RSS unit `kbytes` |
| Java | OpenJDK 17.0.20+8-1-22.04-Ubuntu; JMH 1.37; Jackson 2.18.2; fastjson2 2.0.52 |

第一批所有 timed process 的最大 RSS 为 `226408 kbytes`；第二批为 `226396 kbytes`。归档 SHA-256：第一批 `6674e9ea391f2bb829616d4126aa992754e6e393e53e50e8d6ff2e2d30dc3dd1`，第二批 `60aee5c466081ff3557f8a35c5f859406551b9e46991fea9f07d057335182202`。两批共 1540 个 workload-library-round 单元，全部保留 raw report、日志、manifest、metadata 和 RSS sidecar。稳定行仅用于复核；noisy 行不支持稳定精确跨库排名。

复核时在归档解压目录执行 `sha256sum -c checksums.txt`，再用仓库中的 `benchmarks/full-seven-library/summarize_full.py` 重新生成 summary；exact case filter 和 direct executable 命令记录在归档 `metadata.json` 与 `run_full.py` 中。

