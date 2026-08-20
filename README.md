# yjson

`yjson` 是面向仓颉 1.1.0 的 JSON 库，提供可修改的 `JsonValue` AST、
直接 typed codec、流式 API、JSON Schema 子集和紧凑只读 DOM。纯仓颉 core 是默认
实现；两个 Native DOM 后端均为显式 opt-in。

正式发布使用仓颉中心仓中的精确版本依赖；源码 checkout 仍可按各 package
manifest 中的 path dependency 进行开发构建。

## 安装

普通应用只需加入 core package：

```toml
[dependencies]
yjson = "2.0.0"
```

## 运行要求

Pure Cangjie 只要求仓颉 SDK 1.1.0，且 `cjc`、`cjpm` 位于 `PATH`。Native package
另外要求 Python 3、C11 compiler 和 `ar`。Linux x86_64 是当前唯一 qualified 平台。

## 快速开始

只使用 core 不需要 C 编译器、yyjson 或 native archive：

```cangjie verify=run expect="Alice"
package yjson_examples

import yjson.*

main(): Unit {
    let value = YJson.parse("{\"name\":\"Alice\",\"age\":30}")
    let object = value.asObject()
    object.put("active", JsonBoolValue(true))
    println(object.get("name").getOrThrow().asString().value)
    println(YJson.stringifyPretty(object))
}
```

仓库内的可执行首例不使用 Native：

```bash command-ok
cd packages/examples
cjpm run
```

## Typed codec 与宏

内置 codec 可以直接使用：

```cangjie noverify=usage-fragment
let encoded = YJson.encodeStringWith(StringJson, "仓颉 JSON")
let decoded = YJson.decodeStringWith(StringJson, encoded)
```

调用方需要 `@JsonCodec` 时，依赖 runtime+macros 聚合包。该聚合包不再隐式安装
或启用 Native：

```toml
[dependencies]
yjson_all = "2.0.0"
```

```cangjie noverify=usage-fragment
import yjson_all.*

@JsonCodec
class User {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        this.id = id
        this.name = name
    }
}

let text = YJson.toJson(User(7, "Alice"))
let user = YJson.fromJson<User>(text)
```

同一个支持 compact fast reader 的生成对象 codec 被高频重复解码时，可以在循环外
解析一次 fast decoder，避免每次泛型调用的运行时类型解析：

```cangjie noverify=usage-fragment
let decoder = YJson.fastDecoder(UserJson)
let userFromString = decoder.decodeString(text)
let userFromBytes = decoder.decodeBytes(unsafe { text.rawData() })
```

无配置重载使用生成的 compact fast reader；传入显式 `JsonReadConfig` 时保持普通
codec 的完整配置语义。不提供生成式 fast-decoder 合同的自定义 codec 会抛出
`JsonException`，其错误码为 `codec_contract`。

不可信输入可通过 `JsonReadConfig` 同时限制完整文档、单个解码字符串/key、根容器
字节数和嵌套深度；三个字节预算默认 `0`（不限制）。内存、stream、typed decode 和
两个 Native DOM backend 使用相同错误码。完整单位与兼容性说明见
[Resource limits](docs/resource-limits.md)。

`@JsonCodec` 在调用方编译期间处理调用方 `src/` 中的类型，不依赖运行时反射。
泛型实参必须有内置 codec 或同样可生成的 codec；参与生成的实例字段必须显式声明
类型，不可变字段需要由可用构造函数接收。完整下游 fixture 位于
[`packages/codec_integration`](packages/codec_integration)。

### Public fast bridges and package pairing

生成的 fast collection codec 会调用 `JsonFastReader` 的公开容量提示
bridge；该方法只服务于宏生成代码，不是应用层的容量保证。可选的
`JsonNativeFloatParserBackend` 和 `yjson_native` 的 Float64 `@FastNative`
bridge 也属于显式、进程级 backend API。它们的稳定契约、并发边界、C ABI
和兼容性清单见 [Public API inventory](docs/public-api-inventory.md)。

由于宏代码在调用方编译，`yjson`、`yjson_macros`、`yjson_all`、
`yjson_native` 和 `yjson_yyjson` 必须使用同一发布版本；当前版本是 `2.0.0`。
普通应用优先使用 `yjson_all = "2.0.0"`，直接组合 runtime 与 macro 时也要分别
固定为 `yjson = "2.0.0"` 和 `yjson_macros = "2.0.0"`。

## 选择 JSON representation

| Backend | 默认 | 内存与生命周期 | 适用场景 | 不适用场景 |
|---|---|---|---|---|
| Pure Cangjie | 是 | GC 管理，无显式关闭 | typed codec、AST、可移植默认、语义 oracle | 受 GC large-object geometry 限制的超大 DOM |
| Custom Native Compact | 否，受支持 opt-in | C-owned，必须 `close()` | 较低内存、受控语义 fallback、超大对象 lookup | 希望完全 GC 管理的 API |
| yyjson Direct Native DOM | 否，受支持 opt-in | C-owned，必须 `close()`；部分 workload 以空间换速度 | 实测通用 Native DOM 最快路径、coarse query、bulk traversal、serialize | 自动加速 `JsonValue.parse`，或百万节点逐节点 FFI 遍历 |

详细合同见 [Backend 指南](docs/backends.md)。选择 backend 是显式 API 决策；库不按
输入大小或文件名自动切换。

### Pure Cangjie Compact

```cangjie noverify=usage-fragment
let bytes = unsafe { "{\"name\":\"Alice\"}".rawData() }
let document = YJson.parseCompact(bytes)
println(document.root().get("name").getOrThrow().asString())
```

### Custom Native Compact

额外依赖 `packages/yjson_native`。它从源码构建 C11 archive，不依赖 yyjson：

```cangjie noverify=requires-native-package
import yjson.*
import yjson_native.*

let bytes = unsafe { "{\"name\":\"Alice\"}".rawData() }
try (document = NativeCompactJsonDocument.parse(bytes)) {
    println(document.root().get("name").getOrThrow().asString())
}
```

### yyjson Direct Native DOM

额外依赖 `packages/yjson_yyjson`。包内固定 vendored yyjson 0.12.0，构建无需
网络：

```cangjie noverify=requires-yyjson-package
import yjson.*
import yjson_yyjson.*

let bytes = unsafe { "{\"count\":42}".rawData() }
try (document = YyjsonCompactJsonDocument.parse(bytes)) {
    println(document.getRootInt("count").getOrThrow())
    println(document.toString())
}
```

Native document 是显式 `Resource`。正常路径必须确定性 `close()`；析构器只用于
泄漏兜底。它们不是线程安全对象：调用方必须外部同步，`close()` 需要独占所有权，
不得与 lookup、traversal 或 serialization 并发。value view 会持有 owner，但 owner
关闭后所有操作确定失败。

## 读取、输出与错误

默认读取忽略未知字段、重复键 LastWins，并尽量把整数保留为精确 `Int64`。
`JsonReadConfig` 可选择 Reject duplicate、Reject unknown field 或
`PreserveLiteral`。decoded key 参与重复判断，所以 `"a"` 与 `"\u0061"` 是同一个键。

`JsonException` 提供 `code`、`byteOffset`、`line`、`column` 和 `path`。三个 backend
都拒绝 malformed JSON，但 Native adapter 的部分语法错误类别比 Pure 粗；不要依赖
底层 yyjson 数字错误码。精确矩阵见 [Backend 指南](docs/backends.md)。

`JsonWriteConfig.compact` 生成紧凑输出，`JsonWriteConfig.pretty` 生成格式化输出。
`encodeToStreamWith` / `decodeFromStreamWith` 不关闭调用方 stream；当前 stream decode
会先读完剩余输入，并非恒定内存增量 parser。

## JSON Schema

`JsonSchema.parse` 读取 Schema；`validate` 返回错误列表，`validateOrThrow` 抛出
`JsonValidationError`。当前覆盖 boolean schema、本地 `$ref`、`type`、`enum`、
`const`、数值/字符串边界、`required`、`properties`、`items`、`allOf`、`anyOf`、
`oneOf` 和 `not`，不是完整 draft 2020-12 实现。

## 性能对比

下面的 typed-decoder 结果来自 SSH Server 的 Intel Xeon Gold 6248R，固定 CPU 8，
Cangjie SDK 20260803、Cangjie `-O2` 和 `cjHeapSize=128MB`。除明确标注的 screen
外，每项使用 11 组交替样本；`ns/op` 越低越好，“提升”定义为
`(baseline - candidate) / baseline`。baseline 是同一 workload 的变更前对照，
不是另一套库的结果。

### 当前保留的 typed decoder 路径

| 路径 | Workload | 输入 | Baseline (ns/op) | Candidate (ns/op) | Paired median 提升 | CV (baseline/candidate) | 状态 |
|---|---|---:|---:|---:|---:|---:|---|
| Ordered field probe | ProfileRecord | string | 825.629 | 720.801 | +12.68% | 0.39–1.44%* | 保留 |
| Ordered field probe | ProfileRecord | bytes | 863.206 | 759.710 | +12.09% | 0.39–1.44%* | 保留 |
| Ordered field probe | Person | string | 2974.754 | 2191.537 | +26.56% | —* | 保留 |
| Ordered field probe | Person | bytes | 3015.710 | 2558.319 | +17.15% | —* | 保留 |
| Reusable generated fast decoder | ProfileRecord | string | 2136.718 | 1781.112 | +16.64% | 3.32% / 2.38% | 保留；string baseline 超出 3% 目标 0.32 个百分点 |
| Reusable generated fast decoder | ProfileRecord | bytes | 2272.406 | 1890.617 | +16.80% | 2.94% / 2.81% | 保留 |

`*` Ordered field probe 的 ProfileRecord 样本 CV 为 0.39–1.44%；Person 的框架样本
受 GC 影响较大，作为方向性 regression guard，不冒充低方差延迟结论。Reusable
fast decoder 的 string 结果同时由 paired effect、硬件计数器和 profile 支持；bytes
结果直接满足每侧 CV 不超过 3%。实现说明和原始限制见
[`docs/performance.md`](docs/performance.md)。

| 路径 / 固定 probe | Cycles median | Instructions median | Max RSS median | 辅助样本 |
|---|---:|---:|---:|---|
| Ordered field probe / ProfileRecord string | 753.4M → 675.1M | 1.823B → 1.572B | 91,712 → 91,636 KiB | 五组硬件计数器、五组 RSS |
| Reusable generated fast decoder / ProfileRecord string | 528.4M → 484.2M (-8.38%) | 1.050B → 981.6M (-6.48%) | 75,044 → 75,540 KiB (+0.66%) | 七组 `perf stat`、五组 RSS |

### 与其他库的对比

以下是当前源码在同一 SSH Server 上的一次跨库 benchmark snapshot：Intel Xeon Gold
6248R、CPU 8、Cangjie SDK `1.1.0-alpha.20260803040049`、Cangjie `-O2`；
Java 对照使用 OpenJDK 11.0.31 和 fastjson2 2.0.52。Cangjie 侧使用
`cjpm bench`，Java 侧使用仓库内的独立 harness；两种运行时的 GC 和计时器不同，
所以这张表用于 workload 透视，不替代前面的 paired regression gate。

| 库 | 版本 / revision | 覆盖样本 | 状态 |
|---|---|---:|---|
| yjson | 当前源码 | 60 | 已测；其中 36 个场景与两种外部对照完全重合 |
| `stdx.encoding.json` | 0.0.3 | 40 | 已测 |
| Java fastjson2 | 2.0.52 / OpenJDK 11.0.31 | 36 | 已测 |
| `cjfast_json` | `eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65` | 0 | 未覆盖：pinned manifest 在 SDK 1.1.0 下导入 `stdx.encoding.json` 却未声明依赖，`cjpm bench` 直接失败 |

下表只列出 yjson、stdx 和 fastjson2 都有结果的 36 个场景。数值单位为 ns/op，
越低越好；倍率为“对照库 / yjson”，小于 `1.00x` 表示对照库更快。`cjfast_json`
没有可填数字，不用旧 SDK 或其它 harness 的结果替代。

| 场景 | 操作 | 载荷 | 输入 | yjson | stdx.json | fastjson2 | stdx/yjson | fastjson2/yjson |
|---|---|---|---:|---:|---:|---:|---:|---:|
| AST | parse | Person | ast | 3,849 | 38,980 | 2,035 | 10.13x | 0.53x |
| AST | stringify | Person | ast | 6,819 | 63,360 | 1,233 | 9.29x | 0.18x |
| Pretty JSON | decode | Person | string | 5,473 | 110,100 | 4,712 | 20.12x | 0.86x |
| Pretty JSON | encode | Person | string | 10,780 | 144,800 | 1,399 | 13.43x | 0.13x |
| 基础对象 | decode | Address | bytes | 844 | 61,100 | 374 | 72.39x | 0.44x |
| 基础对象 | decode | Address | string | 754 | 61,020 | 439 | 80.93x | 0.58x |
| 基础对象 | decode | Person | bytes | 4,068 | 100,800 | 1,003 | 24.78x | 0.25x |
| 基础对象 | decode | Person | string | 3,478 | 100,500 | 1,524 | 28.90x | 0.44x |
| 基础对象 | encode | Address | bytes | 1,748 | 109,200 | 1,104 | 62.47x | 0.63x |
| 基础对象 | encode | Address | string | 1,872 | 109,200 | 432 | 58.33x | 0.23x |
| 基础对象 | encode | Person | bytes | 4,694 | 129,100 | 834 | 27.50x | 0.18x |
| 基础对象 | encode | Person | string | 5,347 | 129,000 | 918 | 24.13x | 0.17x |
| 大 Map | decode | HashMap<String, Int64>[64] | string | 101,800 | 420,900 | 13,788 | 4.13x | 0.14x |
| 大 Map | encode | HashMap<String, Int64>[64] | string | 73,310 | 253,900 | 6,220 | 3.46x | 0.09x |
| 大数组 | decode | ArrayList<ProfileRecord>[64] | string | 43,970 | 743,000 | 14,501 | 16.90x | 0.33x |
| 大数组 | encode | ArrayList<ProfileRecord>[64] | string | 99,410 | 493,900 | 12,419 | 4.97x | 0.12x |
| 字段顺序 | decode | Person | string | 4,838 | 105,600 | 1,075 | 21.83x | 0.22x |
| 嵌套对象 | decode | ProfileBundle | bytes | 9,375 | 107,200 | 979 | 11.44x | 0.10x |
| 嵌套对象 | decode | ProfileBundle | string | 8,008 | 105,400 | 1,571 | 13.16x | 0.20x |
| 嵌套对象 | encode | ProfileBundle | bytes | 13,610 | 132,500 | 991 | 9.73x | 0.07x |
| 嵌套对象 | encode | ProfileBundle | string | 13,840 | 131,900 | 1,018 | 9.53x | 0.07x |
| 数值边界 | decode | UInt64Envelope | bytes | 9,167 | 91,610 | 1,295 | 9.99x | 0.14x |
| 数值边界 | decode | UInt64Envelope | string | 8,070 | 91,990 | 1,859 | 11.40x | 0.23x |
| 数值边界 | encode | UInt64Envelope | bytes | 9,184 | 125,900 | 2,457 | 13.71x | 0.27x |
| 数值边界 | encode | UInt64Envelope | string | 8,413 | 125,800 | 5,306 | 14.95x | 0.63x |
| 时间/大数 | decode | TemporalStats | bytes | 15,600 | 103,200 | 1,273 | 6.62x | 0.08x |
| 时间/大数 | decode | TemporalStats | string | 16,390 | 102,300 | 1,652 | 6.24x | 0.10x |
| 时间/大数 | encode | TemporalStats | bytes | 22,210 | 137,200 | 1,620 | 6.18x | 0.07x |
| 时间/大数 | encode | TemporalStats | string | 25,530 | 137,700 | 2,677 | 5.39x | 0.10x |
| 未知字段 | decode | Person | string | 6,467 | 119,100 | 2,414 | 18.42x | 0.37x |
| 深层嵌套 | decode | ArrayList<HashMap<String, ArrayList<ProfileRecord>>> | string | 47,010 | 473,400 | 8,839 | 10.07x | 0.19x |
| 深层嵌套 | encode | ArrayList<HashMap<String, ArrayList<ProfileRecord>>> | string | 80,640 | 331,100 | 6,849 | 4.11x | 0.09x |
| 转义/Unicode | decode | String | bytes | 1,910 | 57,770 | 731 | 30.25x | 0.38x |
| 转义/Unicode | decode | String | string | 1,826 | 57,470 | 516 | 31.47x | 0.28x |
| 转义/Unicode | encode | String | bytes | 1,323 | 107,400 | 541 | 81.18x | 0.41x |
| 转义/Unicode | encode | String | string | 1,850 | 108,000 | 401 | 58.38x | 0.22x |

### 六个固定 workload 的完整增益矩阵

这是各轮实验相对各自 baseline 的 paired median 增益。`—` 表示该路径没有可比测量；
被拒绝的 session/View 数字保留用于复盘，不代表生产 API 承诺。

| Workload | Ordered probe（保留） | Reusable decoder（保留） | Reusable session（拒绝） | Adaptive session B（拒绝） | Borrowed View（拒绝） |
|---|---:|---:|---:|---:|---:|
| ProfileRecord string | +12.68% | +16.64% | +62.79% | +67.48% | +52.19% |
| ProfileRecord bytes | +12.09% | +16.80% | +63.47% | +65.44% | +56.56% |
| Address string | — | — | +64.97% | +69.73% | +54.81% |
| Address bytes | — | — | +60.79% | +57.24% | +56.53% |
| Person string | +26.56% | — | -4.23% | -1.27% | +31.99% |
| Person bytes | +17.15% | — | -3.20% | -0.44% | +42.29% |

session 的六项数字是第二轮 11 组诊断中位数；Adaptive session B 是五组 screen；
Borrowed View 是首轮 11 组三路比较。不同实验的绝对 baseline 不能横向比较。

### 被拒绝实验的验收结果

| Experiment | Latency evidence | Allocation / hardware evidence | Gate 结论 |
|---|---|---|---|
| Reusable fast-decode session | ProfileRecord/Address +60.79%–+64.97%；Person -4.23% / -3.20% | GC count -42.86%，GC-freed bytes -45.11%；ProfileRecord string cycles 495.9M → 266.3M、instructions 999.0M → 355.6M；RSS 80,754 → 58,310 KiB | 拒绝：Person 回退、CV 超过 3%，普通 decoder 也未满足 2% 回退门槛 |
| Adaptive session B | Flat objects +57.24%–+69.73%；Person -1.27% / -0.44% | 五组 screen 中仍有 CV >3%，普通 decoder guard 超过 2% | 拒绝；未启动 11 组正式测量 |
| Generated Borrowed View | +31.99%–+56.56%，六项均 11/11 paired positive | GC count/freed bytes -100%；CV 2.87%–11.68%；普通 decoder 在 ProfileRecord bytes -4.87%、Person string -2.49% | 拒绝：CV 和普通 decoder 回退门槛失败；公共 API 已移除 |
| Person internal hot-path screens | Fixed-name +0.80% / -0.90%；inline path -5.79% / +8.20%；loop fusion +0.85% / +1.39%（string / bytes） | guards 出现约 2%–4% 回退；loop fusion 使 ProfileRecord string 回退 3.71% | 拒绝；没有单项同时达到 Person 与 guard 门槛 |

### Native DOM 参考范围

Round-18 的 yyjson semantic-adapter 保留范围同样在 Xeon Gold 6248R、CPU 8、SDK
20260803、`-O2` 下测得；这些是 backend-specific regression reference，不是 Pure
Cangjie typed codec 的替代结果。

| Workload | Retained yyjson semantic-adapter range |
|---|---:|
| Flat64 | 0.59–0.62 s |
| ObjectArray64 | 0.34 s |
| numeric64 | 0.42 s |
| Canada | 3.5 ms |
| Twitter | 0.89 ms |
| CITM | 1.55 ms |

原始样本、计数器、RSS、GC 和重测规则集中在
[`docs/performance.md`](docs/performance.md)；跨 stdx、cjfast_json 或 Java 的结果只有
在相同语义、输入、机器、SDK 和构建参数下才可比较。

## 构建与验证

要求仓颉 SDK 1.1.0。纯 core 只要求 `cjc`/`cjpm`。Native package 另外要求 Python 3、
C11 编译器和 `ar`；构建脚本尊重 `CC` 与 `AR`。

```bash command-ok
cjpm test
(cd packages/yjson_native && cjpm test)
(cd packages/yjson_yyjson && cjpm test)
YJSON_FUZZ_CASES=5000 scripts/release_native_checks.sh
```

仓库的 GitCode CI 将这些 gate 拆成 core、examples、外部 macro consumer、Custom
Native、yyjson、Clang/GCC、sanitizer、短 fuzz 和 yyjson 双版本符号隔离 job；50k
fuzz 为定时/手动扩展 gate。CI runner 必须预装一套一致的仓颉 1.1 SDK。yyjson
implementation symbols 在最终 shared library 中被 localize，不会导出给宿主应用。

Linux x86_64 是当前唯一 qualified 平台。production Native DOM 不要求 AVX2；scanner
的可选 SIMD path 有 scalar fallback。AArch64 仅为 source-portable candidate，尚未实际
qualification；musl 未验证。

## 发布与许可证

- 项目许可：[Apache License 2.0](LICENSE)
- 可选 yyjson 许可与来源：[Third-party notices](THIRD_PARTY_NOTICES.md)
- Release checklist：[docs/release-checklist.md](docs/release-checklist.md)
- 性能方法与限制：[docs/performance.md](docs/performance.md)
- 实现边界：[docs/architecture.md](docs/architecture.md)

历史 benchmark、competitor 和 `target/perf-results` 不属于 runtime package。性能数字只
能在 representation、语义、机器、SDK 和构建参数一致时比较。
