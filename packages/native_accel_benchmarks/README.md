# Native 加速性能测试

本包用于仓库内的发布性能测试，通过根目录下的 `scripts/json_native_accel_perf_run.py` 运行。
普通应用只需调用一次 `YJsonNativeAccel.initialize()`，随后继续使用 `YJson` API。

首次普通 `YJson` 调用会固定引擎，因此测试脚本分别启动 Pure 和 Native 进程。
正式测量交替进程顺序运行 11 轮，将两侧固定到同一 CPU，堆大小设为 128 MiB，
并使用 `/usr/bin/time -v` 记录 RSS。每份原始报告都保留校验和。

## 结果校验

各进程在初始化测试数据时，为每个用例向标准输出写入一行内容摘要。这一步不计入测量时间：

```text
CHECKSUM <case> <16-hex-fnv1a-64>
```

摘要使用 FNV-1a 64，初始值为 `0xcbf29ce484222325`，素数为 `0x100000001b3`。
不同用例校验以下字节：

- 字符串写入（`writeNumericArray`、`writeEscapedStrings`、`writePlainStrings`）：序列化 JSON 字符串的 UTF-8 字节。
- 字节写入（`writeNumericBytes`、`writeEscapedBytes`）：序列化得到的字节数组。
- 读取（`readNumericArray`、`readNumericDocument`）：解析值的确定性摘要，包含数量和末尾元素。

测试脚本从进程日志提取摘要，并在 `manifest.csv` 中关联对应的原始报告行。
每个用例的 Pure 和 Native 摘要必须一致。不一致表示两侧可观察结果不同，整批测试失败。

## 内存测量

脚本用 `/usr/bin/time -v -o <rss-file>` 启动每次测量，从输出文件读取
`Maximum resident set size (kbytes)`。正式测量必须取得两侧全部 11 轮的 RSS；
任意一次缺失都会使整批测试失败。

## 发布验收条件

声明加速的读写用例必须分别满足以下条件：

- 耗时比 `Native/Pure <= 0.95`。
- 11 对测量中至少赢得 6 对。
- 每次测量都有 RSS，且 Pure 与 Native 的内容摘要一致。

普通稳定性用例要求 `Native/Pure <= 1.05`。两侧每个用例的变异系数（CV）都必须不超过 5%。

只有默认的 11 轮测量可用于正式验收，其他 `--runs` 值仅用于诊断。
任一侧超出 CV 限制时，丢弃整批结果，重新运行全部 11 轮，最多重跑一次。
第二批仍不稳定时，该版本未通过性能验收。

`0.1.0` 的性能结论需要对应版本的实测记录，不能直接引用历史结果。
记录须包含源码摘要、编译器、平台、CPU 亲和性、堆限制、原始报告校验和、RSS 和测试脚本版本。
记录格式见 [`release/0.1.0/evidence.md`](../../release/0.1.0/evidence.md)。
