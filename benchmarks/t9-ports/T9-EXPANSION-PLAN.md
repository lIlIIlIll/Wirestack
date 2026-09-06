# T9 用例扩充方案（覆盖缺口 → 可执行计划）

> 状态：方案（未实现）。基线：2026-09-03 四库双 SDK 矩阵（22 用例，见
> `/tmp/yjson-t9-matrix-20260904/comparison/comparison.md`）。本方案不改动既有 22 用例，
> 全部新用例独立成组，保证跨日可比性。

## 1. 目标与非目标

**目标**：把 T9 矩阵的覆盖面从"常用热路径核心"扩展到真实业务负载谱的主要区域：
可空字段、边界数值、空容器、未知字段容忍、大单文档、数组嵌套数组，以及 bytes/流式输入
（三库轨）与内存维度。

**非目标**：
- 不改动既有 22 用例的 bean/population/测量语义（跨日锚点：yjson-msgc t9_3_9 29.84µs vs 29.5µs）。
- 不改变单次 run 快照契约（用户既定）。
- 不追求"所有场景"——以下缺口为**库能力固有限制**，明确排除：
  - **enum 字段**：cjjson 不支持 enum，四库公共面无法纳入。
  - **PerfLargeList（200×110 字段大列表）**：msgc 编译器优化器崩溃
    （`packages/benchmarks/src/bench_t9_throughput.cj:681` 注释），以 200×10 字段小项大文档
    替代（t9_5_9/10）；原生大列表等上游崩溃修复后另启。
  - **错误路径开销**：异常成本主导，库间可比性差，列 P2 观察项而非正式用例。

## 2. 四库能力矩阵（核实结论，证据 = 文件:行号）

| 能力 | yjson | json4cj | cjjson | Jackson |
|---|---|---|---|---|
| Option 字段 | ✓ 宏专用处理 `packages/yjson_macros/src/json_codec.cj:117-131,536`（`optionInner`/`__yJsonWriteStringOption`） | ✓（`CodableSmoke_test.cj` 等多处使用） | ✓ 嵌套 Option/Option\<Bean\>（`NestedClass_test.cj:28` `Option<Simple>`；`JsonDefault_test.cj` `?String/?Simple`） | ✓（用可空字段 + null，不用 Optional 类型避免 jdk8 模块依赖） |
| 缺失字段默认值 | 待运行核实（默认忽略缺失？） | 待运行核实 | ✓ `@JsonDefault`（`JsonDefault_test.cj`）+ `@JsonAdapter[allowNull]`（`AllowNull_test.cj:16-24`：缺失→默认值、null→默认值） | ✓ |
| 未知字段容忍 | 待运行核实 | 待运行核实 | ✓ 生成代码逐字段 `jsonObj.containsKey($jsonName)`（`src/macros/HandleClass.cj:84,218`、`HandleStruct.cj:177`）→ 多余 key 跳过 | ✓（默认 FAIL_ON_UNKNOWN 需关，或 `@JsonIgnoreProperties`） |
| Int64 极值 | ✓（Int64 原生） | ✓（预期，P0 落地时验证） | ✓ `BasicClass_test.cj:61-112`（i64 = 9223372036854775807；u64 上限即 Int64.MAX，注意） | ✓ long |
| Array\<Array\<Int64\>\> | ⚠ 未找到直接证据（P0 落地时首验） | ✓ `json4cj-core/src/test/ext/IJsonAdapter_test.cj:135-140` 显式往返 | ⚠ 未找到直接证据（`WithGenericType_test.cj` 无此形状；但 `HashMap<String, Array<Int64>>` 已在现网矩阵中工作，宏组合适配器大概率支持） | ✓ |
| bytes 输入 | ✓ `YJson.fromJson(YJsonByteArrayInputStream(bytes), codec:)`（`src/json_coverage_contracts_test.cj:241,694`） | ✓ stream 包 `json4cj-core/src/stream/{JsonReader,JsonStreamFactory,JsonToken}.cj` 拉式 API | ✗ **String-only API**（三库轨，标注不可比） | ✓ 原生 byte[]（现网 JacksonBench 即 writeValueAsBytes/readValue(bytes)，`JacksonBench.java:23`） |
| 流式拉取 | ✓（InputStream 重载同上） | ✓ 同上 | ✗ | ✓ JsonParser |
| 大文档 | ✓ | ✓ | ✓（String 承载 1MB 无压力；性能另测） | ✓ |
| enum | ?（未核实） | ? | ✗ | ✓ |
| 多态/继承 | ? 未核实 | ⚠ `@JsonVariant` 未在 annotations/src grep 到（P1 核实） | ⚠ 有接口测试文件（`ClassWithInterface_test.cj`），语义未核实 | ✓ |
| pretty-print 输入解析 | ✓（解析器容忍空白，预期） | ✓（预期） | ✓（预期） | ✓ |

注：Jackson 现网用 bytes（`writeValueAsBytes`/`readValue(bytes)`），三个 Cangjie 库用 String——
既有矩阵已存在该不对称；Track A 新用例统一 `writeValueAsString` 对齐，bytes 差异归 Track B。

## 3. 用例目录

### Track A：四库公共面（进主矩阵，t9_5_x）

| ID | bean / 负载 | population 要点 | 测量语义 | 备注（变通） |
|---|---|---|---|---|
| t9_5_1_optionSerialize | `OptionBean { name: ?String; count: ?Int64; inner: ?InnerBean; tag: ?String }`（InnerBean 3 字段） | name=Some("matrix")、count=None、inner=Some(InnerBean)、tag=None | serialize（含 None→null 写出） | cjjson None 的写出形态（null vs 省略）落地首验；若省略则四库 payload 有差异，接受并在结果页标注 |
| t9_5_2_optionDeserialize | 同上 bean | payload 含显式 null + 全 Some 两种各测一次？——**否**，单 case 单语义：payload = 全字段 Some（无 null） | deserialize（读 inner 字段） | 规避 cjjson allowNull 差异；null 变体列 P1 |
| t9_5_3_optionRoundTrip | 同上 | 同 t9_5_2 payload | roundtrip | 名字含 RoundTrip 自动分组 |
| t9_5_4_emptyContainersSerialize | `EmptyBean { arr: Array<Int64>; m: HashMap<String,Int64>; strs: Array<String>; inner: InnerBean }`（全部默认空） | 默认构造 | serialize | 无 Float，无 Int/Float 不对称风险 |
| t9_5_5_emptyContainersDeserialize | 同上 | payload = `{"arr":[],"m":{},"strs":[],"inner":{...}}` | deserialize（读 inner 字段） | 验证空集合解析开销 |
| t9_5_6_int64ExtremesSerialize | `ExtremeBean { a: Int64; b: Int64; c: Int64; d: Int64; e: Int64 }` | 9223372036854775807 / -9223372036854775808 / -1 / 0 / 1 | serialize | cjjson u64 上限即 Int64.MAX（`BasicClass_test.cj:112`），不用 UInt64 |
| t9_5_7_int64ExtremesDeserialize | 同上 | 同 payload（字面量直写 JSON） | deserialize（读 a） | 大整数字面量解析路径 |
| t9_5_8_unknownFieldDeserialize | 复用 `CollectionBean` 形状 | payload = 已知字段 + 5 个多余 key（含 1 个 512B 字符串值） | deserialize（读 intArray.size） | cjjson 天然跳过（宏 containsKey）；**yjson/json4cj 若任一库抛异常 → 降级三库并在结果标注**（P0 首验项） |
| t9_5_9_largeDocumentSerialize | `LargeDoc { items: Array<SmallItem>; index: HashMap<String,Int64> }`，`SmallItem` 10 字段；items=200 条 → ≈1MB | init() 生成一次 | serialize | 规避 >100 字段类（编译器崩溃约束）；Jackson 用 writeValueAsString 对齐 |
| t9_5_10_largeDocumentDeserialize | 同上 | 同 payload（init 生成后 toJson 固化） | deserialize（读 index.size） | 大文档解析/树构建路径 |
| t9_5_11_arrayOfArraySerialize | `MatrixBean { grid: Array<Array<Int64>> }` 50×20 | grid[i][j]=i*20+j | serialize | yjson/cjjson 首验；不可行 → 降级三库（json4cj/Jackson 有证据） |
| t9_5_12_arrayOfArrayDeserialize | 同上 | 同 payload | deserialize（读 grid.size） | 同上 |

### Track B：三库 bytes/流式轨（t9_b_x；cjjson 无 bytes/stream API，明确不可比）

| ID | 内容 | API（证据） |
|---|---|---|
| t9_b_1_bytesParsePrimitive | PrimitiveBean bytes 解析（512B payload，预热后测） | yjson `YJson.fromJson(YJsonByteArrayInputStream(bytes), codec:)`（`json_coverage_contracts_test.cj:241`）；json4cj stream `JsonStreamFactory` 组 Reader 逐 token 填 bean；Jackson `mapper.readValue(byte[], Class)` |
| t9_b_2_bytesParseLargeDoc | t9_5_9 的 1MB payload bytes 解析 | 同上 |
| t9_b_3_streamPullLargeDoc | 1MB 流式拉取（只计数不建对象，测纯解析吞吐） | yjson InputStream 重载；json4cj `JsonReader` 逐 token；Jackson `JsonParser`。**语义对齐风险**：三库 pull API 粒度不同（token vs 事件），按"遍历全部 token/字节"统一语义，结果标注为解析器核心吞吐而非端到端 |

### Track C：内存维度（改 runner，不加用例）

- `scripts/run_t9_throughput.py` 增加 `--memory`：把 `subprocess.run(cjpm bench …)` 改为
  `/usr/bin/time -v` 包裹，解析 `Maximum resident set size (kbytes)` 写入 manifest 新列
  `max_rss_kb`。每 case 一个进程，天然隔离，无需改 bench 代码。
- `scripts/summarize_t9_matrix.py`：summary 增列 `max_rss_mb`；comparison.md 加"内存"小节。

### Track D：Jackson 计时方法学（JMH 迁移）

- 现状：手写循环计时（预热 1s → 测量 3s，`JacksonBench.java:18-20`），无 JMH 的 OSR/去优化/
  死代码消除防护，小用例（0.34–0.45µs）存在系统性偏乐观风险。
- 方案：新建 `docs/jackson-bench/jmh/`（jmh-core 1.37 + jmh-generator-annprocess），每 case 一个
  `@Benchmark`，`-f 1 -wi 3 -i 5 -w 1s -r 1s`，输出后处理成同款 `t9_* <x> us` 行格式 →
  `run_t9_jackson.py` 仅改调用命令，解析逻辑不动。
- bytes/string 双模式都保留（现网 `JacksonBench.java:208-209` 已有先例）。

### 明确排除

| 缺口 | 排除理由 |
|---|---|
| enum 字段 | cjjson 不支持（已确认） |
| PerfLargeList 200×110 | 编译器优化器崩溃（蓝本注释），以 200×10 大文档替代 |
| 错误路径（畸形/截断输入） | 异常成本主导，P2 观察项 |
| NDJSON 多对象 | 逐行循环开销主导，P2 观察项 |
| 多态/继承字段 | json4cj @JsonVariant 与 cjjson 接口语义未核实，P1 核实后再定 |
| 并发/多核 | 单核 pin 是矩阵契约；并发正确性属另一测试族 |

## 4. 集成清单（每个新用例的改动位置）

1. `scripts/run_t9_throughput.py`：`CASES` 元组追加 12 个 t9_5_*（顺序即运行顺序）；`ordered_cases` 的轮转逻辑自适应（按 len(CASES)）。**同时新增 `LEGACY_CASES`（现 22 个）常量。**
2. **load() 契约版本化**（`scripts/summarize_t9_three_way.py:15-44`）：改为按 `metadata.json` 的 `cases` 列表分流——== LEGACY_CASES → 校验 summary 22 行且 ⊆ legacy；== 当前 CASES → 校验全量。历史结果目录（含 2026-09-03 矩阵）保持可加载。
3. `scripts/run_t9_jackson.py`：不改（自动跟随新 CASES）；`JacksonBench.java` 同步加 12 个 case 的 bean + `bench(...)` 行，**顺序与 CASES 严格一致**（`RESULT` 正则按序匹配，`run_t9_jackson.py:78` 强校验）。
4. 四份 bench 文件同构新增：`packages/benchmarks/src/bench_t9_throughput.cj`（蓝本）、cjjson 移植文件（注意 cjjson Int/Float 不对称——上述 bean 均无 Float 字段；Option 序列化形态首验）、json4cj `T9BenchThroughput_test.cj`（Server clone 内）、JacksonBench.java。
5. `scripts/summarize_t9_matrix.py`：`group()` 无需改（新命名已符合 substring 规则——反序列化用例一律含 `Deserialize`，如 `t9_5_8_unknownFieldDeserialize`）；comparison 表自动扩行。
6. `scripts/prepare_t9_cjjson_copy.py` / `prepare_t9_json4cj_copy.py` / `prepare_t9_yjson_copy.py`：无需改（源文件由 rsync/cp 覆盖）。
7. Track C：`run_t9_throughput.py` 加 `--memory` + `/usr/bin/time -v`；matrix 汇总加内存列。

## 5. 分期

| 期 | 内容 | 工作量 | 前置 |
|---|---|---|---|
| P0 | Track A 12 用例：四库 bench 文件同构 + JacksonBench + CASES + load() 版本化 + 跑一轮矩阵。含 3 个首验点（yjson/cjjson 的 Array\<Array\>；cjjson None 写出形态；yjson/json4cj 未知字段容忍） | 1–2 天（含一次全矩阵跑 ~1h） | 无 |
| P1 | Track B 三库轨 3 用例（yjson/json4cj stream API 深读 + 语义对齐设计）；多态可行性核实（@JsonVariant 位置、cjjson 接口、yjson 支持面）；pretty-print 输入 fixture（四库，若 cjjson 验证通过） | 1–2 天 | P0 合入 |
| P2 | Track C 内存列；Track D JMH 迁移；错误路径/NDJSON 观察项 | C：小时级；D：1 天；其余按需 | P0 合入 |

## 6. 验收标准

- P0：新 34 用例（22+12）在 6 cell 全部 PASS 且 init 预检（各库移植文件中的往返断言同步扩展到新 bean）通过；历史 22 行结果目录仍可被 load() 加载并复现旧 comparison 数值；新 comparison.md 含 t9_5_* 行且 Track A 无 ABSENT。
- P1：t9_b_* 仅出现在三库轨表格且 cjjson 列明确标"不可比"；多态结论有源码证据或明确"不可测"。
- P2：comparison.md 出现 max_rss 列；JMH 版 Jackson 数字与手写版同 case 偏差有量化说明。

## 7. 实际执行记录（2026-09-04，与方案的差异）

已落地：Track A 8 个新用例（t9_5_1..t9_5_8）+ Track B 1 个（t9_b_1）+ Track C 内存列 +
Track D JMH 迁移。最终契约 = 22 legacy + 8 coverage = 30 用例（A）+ 1（B）。

**执行中排除的用例（全库同步排除，保留代码待回归）——矩阵 scratch
 运行曾记录候选工作区产物 `{"items":,"items":[...]}` 与
  `Unexpected token at byte 8/9`，栈涉及 `ArrayJsonCodec.readFastWithCursor` /
  `JsonFastReader.failAt`：**

1+2. t9_5_9/t9_5_10/t9_5_11/t9_5_12/t9_b_2/t9_b_3 —— 历史记录将其归为
   `Array<E>`（E 为 bean 或嵌套数组）写路径问题；序列化用例只测 `.size`，
   没有验证产物，所以反序列化失败不能单独定性为 decode bug。
3. t9_5_13（pretty-print 输入）：json4cj `@Codable[fixedSchema]` 流式解码对缩进 JSON
   抛 "Fixed JSON schema field name mismatch"（同序紧凑输入通过 → token 间空白为触发因素）；
   yjson daily 对对象形态 pretty 输入可解析。该用例按库分容差后再回归。

**当前工作区复核**：用 daily SDK 对 clean `26ed85c` snapshot、当前工作区分别做了最小
   `Array<bean>` 与 `Array<Array<Int64>>` 探针；显式/隐式 codec 输出均为单个字段名，
   3000 个 bean + 2000 个 map 项完整 round-trip 通过，50×20 嵌套数组完整 round-trip
   通过。编译器展开的 `writeCompactRawWithWriter` 也只生成一次字段名。因此，历史
   scratch 产物目前无法在仓库 HEAD 或当前工作区复现，根因不能据此归因到现行
   `ArrayJsonCodec`；上述用例继续保守排除，直到用 pinned source/SDK 重现或补充回归证据。

**b_3 语义调整**：三库统一为"流式/缓冲输入构建 bean"（yjson 双输入适配器、json4cj
createReader 两种重载、Jackson readValue(InputStream)），纯 token 计数语义因三库 pull
粒度不可比而放弃。

**关键数字（30 用例 + B 轨，完整表见 comparison.md）**：

> **证据状态标注（2026-09-05）**：以下数字是 2026-09-04 的单次诊断快照
> （`--runs 1`，每 case 单轮、无交替/反转 A/B），**不构成 0.1.0 qualification**。
> 未满足正式 release gate 的前置：11 轮、逐轮交替/反转执行顺序、RSS 采集、
> 内容 checksum 绑定、固定 CPU 之上的可复现性复测。跨日锚点（29.84µs vs 29.5µs）
> 同为单次观测，不代表配对差异。0.1.0 的正式结论以
> `release/0.1.0/evidence.md` 及符合 `docs/maintainers/releasing.md` 门禁的
> 完整批次为准；本段只用于规划与相对量级判断。

- msgc/Jackson geomean：yjson 0.856（新用例拉高：Option/未知字段为 yjson 相对弱项）、
  json4cj 2.548、cjjson 5.145
- daily/msgc：yjson 2.416、cjjson 3.704
- B 轨 t9_b_1（bytes vs String）：yjson 38.7×（msgc）/15.0×（daily）——YJsonByteArrayInputStream
  路径远慢于 String 路径（yjson 优化点）；json4cj 0.98×持平
- 内存（max RSS）：msgc ~84MB vs daily ~331MB（daily 运行时基线高 4×）；json4cj 反序列化
  峰值 105.8MB（intMap 容量提示生效的对照点）
- Jackson JMH vs 手写计时：geomean 0.906 —— 手写计时数字系统性偏乐观 ~10%

**P1 多态判定**：yjson 具备完整判别器式多态编解码（`json_codec.cj:2147-2222`）；
json4cj 具备 @JsonVariant 生成器（`json4cj-annotations/src/macros/VariantEmitter.cj`）；
cjjson 接口实现与 @JsonAdapter 兼容（`ClassWithInterface_test.cj`）但接口类型字段的
分派无证据。三库多态语义不同构，公共面用例需统一 wire 格式（判别器字段）后再设计。
