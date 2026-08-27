# Wirestack：仓颉跨平台 TLS/HTTPS 网络栈仓库实施任务分解

**依据：**《Wirestack：仓颉跨平台 TLS/HTTPS 网络栈重写 PRD》v2.0（2026-08-22）  
**文档类型：** Issue/PR 级实施 backlog  
**主线任务数：** 174  
**条件上游任务数：** 7  
**目标：** 将 PRD 转换为可排期、可并行、可验收、可追踪的仓库任务；不在此文档中改变 PRD 已冻结的产品边界。

> 仓库事实：Wirestack 是独立仓颉绿地网络库仓库，GitHub 为 `lIlIIlIll/Wirestack`。新公共包默认使用 `wirestack.*`，内部实现使用 `wirestack.internal.*`。`cangjie_stdx`、仓颉 SDK、`std.net` 与 runtime 源码均为外部参考或上游仓库，不属于 Wirestack 工作树。实际物理目录与 `cjpm` target 由 M0-002 根据当前仓颉工具链冻结；本 backlog 在此之前只约束逻辑模块边界、依赖方向和验收语义。

---

## 1. 实施总原则

1. **先证据、后上游修改。** `std.net`/runtime 改造只由 M0 门禁失败解锁，禁止为了便利预先扩范围。
2. **Core 与默认实现分离。** TLS/HTTP Core 只能依赖内部 Transport SPI；只有 `transport-stdnet` 可以导入 `std.net`。
3. **公共 API 不泄漏底层。** 不暴露 `TcpSocket`、`StreamingSocket`、`SocketException`、provider native 类型、OpenSSL cipher string 或 `SSL_CTX/SSL*`。
4. **统一操作语义。** DNS、connect、proxy、TLS、HTTP headers/body 只使用单调绝对 Deadline、CancellationToken、结构化错误、trace 和 exactly-once completion。
5. **默认构建无系统 OpenSSL。** provider 构建时确定；不运行时猜测动态库，不失败后自动 fallback。
6. **所有资源有界。** parser、buffer、pool、session、HPACK table、HTTP/2 window/queue/stream、resolver pool 均必须有显式上限。
7. **任务以可合并证据结束。** 每个实现任务必须同时提交测试；涉及性能、安全、平台或资源语义时必须附 benchmark、fuzz、真机或泄漏证据。

---

## 2. 建议仓库逻辑布局

实际目录可按仓库构建系统调整，但依赖方向必须保持。

```text
src/
  internal/
    common/                 # wirestack.internal.common
    transport/              # Transport SPI、Memory/Fault transport
    transport_stdnet/       # 唯一允许依赖 std.net 的默认实现
    resolver/               # Resolver 契约与平台实现
    connector/              # Happy Eyeballs、route
    tls_engine/             # provider bridge、record/handshake pump
    http1/                  # strict codec 与连接状态机
    http2/                  # frame、HPACK、flow control、stream
    platform/
      windows/
      linux/
      apple/
      android/
      harmony/
  tls/                      # wirestack.tls
  http/                     # wirestack.http

tests/
  unit/
  model/
  integration/
  interop/
  platform/
  corpus/

benchmarks/
fuzz/
tools/
docs/
```

以上是逻辑布局建议，不代表已经冻结的 `cjpm` 物理结构。M0-002 必须用实际工具链验证后才能冻结 target/package 映射。

强制依赖方向：

```text
HTTP → TLS → Transport SPI ← StdNetTransport → std.net
```

---

## 3. 项目字段、标签与任务完成定义

### 3.1 建议字段

| 字段 | 值 |
|---|---|
| Milestone | M0～M7 / UP / P1 |
| Area | architecture / core / stdnet / resolver / connector / tls / http1 / http2 / platform / test / perf / security / release / docs |
| Priority | P0 / P1 |
| Complexity | C1 局部；C2 单模块；C3 跨模块；C4 高竞态/平台/协议/安全 |
| Platform | all / windows / linux / macos / android / ios / harmony |
| Gate | none / architecture / conformance / fuzz / benchmark / native-device / security-review / release |

### 3.2 每个 Issue/PR 的最低完成定义

- 任务范围与非目标明确，不顺手复制旧 API 或扩大兼容层。
- 实现、单元测试和必要的确定性竞态测试同 PR；无“后补测试”。
- 新的等待路径接受 `OperationContext`，不新增独立 timeout ownership。
- 新的错误保留 category、phase、code、retryability；不以 message 作为控制流。
- 新队列/缓存/buffer/window 必须有配置或固定上限，并有极限测试。
- 涉及资源终态时验证 exactly-once、幂等 close/abort、registration/timer/waiter 清理。
- 涉及平台能力时必须在真机或原生 VM 运行；仅交叉编译不算完成。
- 涉及性能目标时提交原始 benchmark 输出、环境、baseline 和回归判定。
- 公共 API 变化更新 API 草案、示例和架构依赖守卫。

---

## 4. 关键路径与并行策略

```text
M0 门禁与 provider PoC
  ├─→ Transport SPI 冻结 ─→ M1 Transport/StdNet ─→ M2 Resolver/Connector
  │                                               ├─→ M3 TLS desktop ─→ M4 mobile/Harmony
  │                                               └─→ M5 HTTP/1 codec/pool/server ─→ M6 HTTP/2
  └─→ 条件 UP-* 上游补强（只在门禁失败时插入）

M3 + M4 + M5 + M6 全部通过 ─→ M7 稳定版硬化
```

可提前并行：

- M1 的 `MemoryTransport` 完成后，HTTP/1 codec 和 HTTP/2 frame/HPACK 可在不等待真实 TLS 的情况下开发。
- M2 Resolver/Connector 与 M3 provider bridge 可在 M1 基础接口稳定后并行。
- 各平台 trust/key adapter 可在统一 TrustPolicy、PrivateKeyRef、external signer 契约冻结后并行。
- fuzz corpus、benchmark harness、依赖扫描和可观测性应随模块同步建设，不能留到 M7 才开始。

不可提前：

- 未完成 M0-016/M0-020，不进入正式 provider 集成。
- 未完成 M0-019，不实现会固化 EOF、取消、half-close 的 Transport 代码。
- 未完成 M1-019/M1-020 的终态语义，不实现 TLS truncation 与 graceful close。
- 未完成 M5-005 的 replayability/commit 证据，不实现 retry/redirect。
- 未完成 M6-011/M6-012，不接入 HTTP/2 client/server/pool。

---

## 5.1 M0：`std.net` 采纳验证与架构冻结

**目标：** 先用证据确认 `std.net` 能否承载新 Transport 语义，冻结 Transport SPI、TLS provider、平台基线和最小上游改造集合。

**退出条件：**

- 六平台 GATE-NET-01～07 有可复现报告；
- raw TCP、DNS carrier-thread、Windows copy profile 均有基线；
- TLS provider 选择完成，并通过外部字节流、external signer、external trust、六平台交叉构建 PoC；
- Transport SPI、所有权、取消、EOF、错误语义和 threat model 评审通过；
- 所有需要修改 `std.net`/runtime 的项目都有失败门禁证据。

| ID | 任务 | 责任域 | 复杂度 | 依赖 | PRD 追踪 | 合并/验收条件 |
|---|---|---|---:|---|---|---|
| M0-001 | 盘点现有 TLS/HTTP/std.net 实现与依赖图 | 架构 | C2 | — | PRD §0–3 | 输出当前包、公共 API、OpenSSL/native 依赖、构建脚本、测试与平台差异清单；标出可删除、可复用、必须隔离的路径。 |
| M0-002 | 提出 vNext 逻辑包与目录布局 | 架构 | C2 | M0-001 | PRD §7.1–7.2 | 给出 transport-core、transport-stdnet、resolver、connector、tls-core、trust/key、http1、http2、http-api 的实际仓库映射；不改变公共 API。 |
| M0-003 | 建立架构依赖守卫 | 基础设施 | C2 | M0-002 | D-002/D-003/D-005；PRD §7.2 | CI 能阻止 TLS/HTTP Core 导入 `std.net`、公共 API 暴露 `std.net` 类型、Wirestack 调用 `CJ_MRT_Sock*`、新栈引用旧 OpenSSL bridge。 |
| M0-004 | 建立网络门禁测试框架与统一结果格式 | 测试 | C3 | M0-001 | PRD §9 | 门禁支持平台、场景、迭代、P50/P95/P99、资源计数、日志和原始证据输出；结果可在 CI 和本机复现。 |
| M0-005 | 建立当前 `std.net` raw TCP 基线 | 性能 | C3 | M0-004 | GATE-NET-05；PRD §19.1/§22 | 覆盖 0B/1KiB/16KiB/64KiB/1MiB/100MiB、loopback/LAN、吞吐、延迟、分配、copy、线程、RSS。 |
| M0-006 | 执行 GATE-NET-01：关闭唤醒 | 测试 | C3 | M0-004 | PRD §9 GATE-NET-01 | blocked read/write/connect/accept 在 close/cancel 后 exactly-once 完成；P99 唤醒满足门槛；无死锁、UAF、double-close。 |
| M0-007 | 执行 GATE-NET-02：全双工与关闭竞态 | 测试 | C4 | M0-004 | PRD §9 GATE-NET-02 | 百万级随机 interleaving；一读一写可并行，同方向并发被拒绝，close/abort 后 waiter 全部退出。 |
| M0-008 | 执行 GATE-NET-03：绝对 Deadline | 测试 | C3 | M0-004 | PRD §9 GATE-NET-03 | connect、partial write、idle read、accept 不因内部循环重置预算；偏差满足 PRD 门槛。 |
| M0-009 | 执行 GATE-NET-04：EOF 与关闭证据 | 测试 | C4 | M0-004 | PRD §9 GATE-NET-04 | peer FIN/RST、local close/abort、cancel/read race 可稳定分类；不能分类的平台形成上游阻断项。 |
| M0-010 | 执行 GATE-NET-05：大块数据、复制与 Windows 4KiB 问题 | 性能 | C4 | M0-005 | PRD §9 GATE-NET-05 | 记录各 payload 的 read 次数和 copied bytes；证明新适配路径可达到 raw TCP 门槛；定位 Windows 固定 4KiB 限制。 |
| M0-011 | 执行 GATE-NET-06：泄漏与长时间运行 | 可靠性 | C4 | M0-004 | PRD §9 GATE-NET-06 | 完成 100k connect/cancel/close、100k reset、100k cleanup 和 24h soak；handle/timer/waiter/buffer/GC root 无单调增长。 |
| M0-012 | 执行 GATE-NET-07：移动网络变化 | 平台 | C4 | M0-004 | PRD §9 GATE-NET-07 | Android/iOS/Harmony 真机覆盖 Wi-Fi/蜂窝/飞行模式/前后台/休眠；旧连接可诊断、新连接可重选路、无旧绑定泄漏。 |
| M0-013 | 验证 DNS 是否阻塞 scheduler carrier thread | 性能 | C3 | M0-004 | PRD §9.1/§12 DNS-004 | 高并发解析下记录 carrier 占用与排队；给出 runtime async、平台 async 或有界 blocking pool 的选择证据。 |
| M0-014 | 完成 Windows socket 数据路径 copy profile | 平台 | C3 | M0-005 | PRD §9/§19.1 | 定位每层复制与 buffer 尺寸；提出不越过正式 `std.net` 接口的低复制方案。 |
| M0-015 | 建立 TLS provider 候选矩阵 | 安全 | C3 | M0-001 | PRD §13.2/§28 | 比较 TLS1.2/1.3 client/server、外部字节流、ALPN/SNI、session、external signer/trust、六平台、漏洞响应、fuzz、许可证、OpenSSL 依赖。 |
| M0-016 | 完成 TLS provider 六平台能力 PoC | 安全 | C4 | M0-015 | PRD §13.2 | 至少验证握手驱动、外部 transport、外部 trust、不可导出 key 签名回调、close_notify、交叉构建；形成可运行样例和失败列表。 |
| M0-017 | 冻结最低 OS/API/SDK 版本矩阵 | 平台 | C2 | M0-012,M0-016 | PRD §14/§28 | Windows/Linux/macOS/Android/iOS/Harmony 的最低版本、编译 target、真机/VM 约束进入版本化文档和 CI 配置。 |
| M0-018 | 完成网络栈 threat model | 安全 | C3 | M0-001,M0-015 | PRD §18/§27 | 覆盖供应链、证书/主机名、parser、smuggling、资源耗尽、密钥边界、日志泄密、取消竞态、C ABI；每项映射缓解任务。 |
| M0-019 | 冻结 Transport SPI RFC | 架构 | C4 | M0-006..M0-014 | PRD §10–12/§16–17 | 冻结 ByteSpan、OperationContext、DuplexTransport、Listener、状态机、错误、所有权、EOF、half-close、exactly-once；标注需要上游能力的接口。 |
| M0-020 | 冻结 TLS provider 选择与构建策略 ADR | 架构 | C3 | M0-016,M0-018 | D-007/D-008；PRD §13/§23 | 记录 provider、版本锁定、构建时选择、无运行时 fallback、补丁/回滚责任、许可证与 SBOM 方案。 |
| M0-021 | 形成最小 `std.net`/runtime 改造清单 | 架构 | C2 | M0-006..M0-014,M0-019 | PRD §8.4/§9.1 | 每项必须包含失败门禁、影响平台、最小正式接口、回归测试和禁止旁路方案；无证据项不得进入清单。 |
| M0-022 | 建立 M0 持续门禁 CI | 基础设施 | C3 | M0-004..M0-021 | PRD §21.5 | 平台可用时自动运行短门禁；长 soak/真机任务可手动触发但产出同一结果格式；架构守卫为必过项。 |
| M0-023 | 冻结当前 Linux glibc 支持范围并延后 musl | 架构 | C2 | M0-001,M0-004 | PRD §0.1/§21.5；ADR-0004 | PRD、ADR、backlog、status 和证据一致声明当前 Linux 仅支持 glibc；musl 不记为失败或通过，由 SDK 支持条件触发 P1-011。 |

---

## 5.2 M1：Transport Core 与 `StdNetTransport`

**目标：** 实现独立 Transport 语义和默认 `std.net` 适配器，使上层 TLS/HTTP 不继承现有 socket 的 DNS、timeout、EOF、错误和公共类型。

**退出条件：**

- Transport Core 不依赖 `std.net`；
- 一读一写、half-close、close/abort、Deadline、取消、exactly-once 和结构化错误全部通过；
- 六平台 `StdNetTransport` close/cancel 门禁通过；
- raw TCP 吞吐、延迟和泄漏满足 PRD 门槛。

| ID | 任务 | 责任域 | 复杂度 | 依赖 | PRD 追踪 | 合并/验收条件 |
|---|---|---|---:|---|---|---|
| M1-001 | 创建 Transport Core/StdNet/测试包骨架 | 架构 | C2 | M0-019,M0-022 | PRD §7.1 | 建立实际包、测试、benchmark 与内部可见性；默认构建暂不切换旧实现。 |
| M1-002 | 实现 `ByteSpan` 与 `MutableByteSpan` | Core | C2 | M1-001 | TR-BUF-001 | 范围检查、零复制子区间、advance/slice、空区间语义和边界单测完整。 |
| M1-003 | 实现单调时钟 `Deadline` | Core | C2 | M1-001 | TR-CTX-002/003 | 仅基于 monotonic clock；remaining/expired/child deadline 不可延长父预算；虚拟时钟可测试。 |
| M1-004 | 接入/实现网络取消原语 | Core | C3 | M1-001,M0-019 | TR-CTX-001/004/005 | 确定复用现有 CancellationToken 或提供内部适配；支持注册、解除、已取消 fast-fail、竞态 exactly-once。 |
| M1-005 | 实现 `OperationContext` | Core | C2 | M1-003,M1-004 | TR-CTX-001–005 | 组合 Deadline、CancellationToken、trace；提供继承/缩短 helper；操作前取消不产生网络副作用。 |
| M1-006 | 实现 `NetworkTraceContext` 与空操作事件入口 | 可观测性 | C2 | M1-001 | PRD §20 | trace 只读传播；默认无分配/低开销；不得自动记录敏感数据。 |
| M1-007 | 实现 Transport `NetworkException`/错误枚举 | Core | C3 | M1-001,M0-019 | PRD §16.1 | category、phase、code、retryability、nativeCode、endpoints、cause 可表达；HTTP 4xx/5xx 不进入该模型。 |
| M1-008 | 实现 exactly-once completion 与资源注销原语 | Core | C3 | M1-003..M1-007 | PRD §17 | 取消注册、timer、waiter、callback 在终态只清理一次；race/property test 覆盖。 |
| M1-009 | 实现 Transport 生命周期状态机 | Core | C3 | M1-008 | PRD §10.5/§17 | Created→Open→half-closed→Closing→Closed 及 Aborted/Failed 转移受控；非法操作返回稳定错误。 |
| M1-010 | 定义并实现 `DuplexTransport` 公共内部契约 | Core | C3 | M1-002,M1-005,M1-007..M1-009 | TR-STREAM-001–007 | readSome/writeSome/shutdown/close/abort 语义冻结；空 buffer 不伪造 EOF；同方向并发失败。 |
| M1-011 | 实现 `writeAll`、`readExact` 等通用 helper | Core | C2 | M1-010 | TR-STREAM-003 | 共享父 Deadline；正确处理 partial write/EOF/cancel；不按循环次数重置 timeout。 |
| M1-012 | 定义并实现 `TransportListener` 契约 | Core | C2 | M1-005,M1-007..M1-009 | TR-LISTEN-001 | accept 可取消/超时；close 唤醒；backlog 和错误结构化。 |
| M1-013 | 实现 `MemoryTransport` | 测试 | C3 | M1-010,M1-012 | PRD §6.2/§21.2 | 支持成对端点、partial I/O、half-close、EOF、背压、虚拟调度；用于 TLS/HTTP 确定性测试。 |
| M1-014 | 实现 fault/scripted transport 与虚拟 waiter | 测试 | C3 | M1-013 | PRD §21.2 | 可脚本化延迟、短读写、RST、EOF、cancel race、错误 phase；测试脚本可复现。 |
| M1-015 | 实现 `StdNetTransport` 所有权与构造边界 | StdNet | C3 | M1-010,M0-021 | PRD §8.3/§11.1 | 只接受已解析 IP endpoint；独占 TcpSocket；不缓存 private handle；包装后调用方不可再用 socket。 |
| M1-016 | 实现基于 IP 的 connect attempt | StdNet | C3 | M1-005,M1-015 | PRD §11.1/§11.2 | 不调用 `TcpSocket(String,port)`；记录 local/remote endpoint；Deadline/cancel 通过已验证路径终止。 |
| M1-017 | 实现 `StdNetTransport.readSome` | StdNet | C4 | M1-002,M1-008..M1-010,M1-015 | PRD §11.2–11.4 | 映射 Data/EndOfStream/Cancelled/Closed；不将 local close 伪装为 EOF；支持一个并发 reader。 |
| M1-018 | 实现 `StdNetTransport.writeSome` 与有界 staging buffer | StdNet | C4 | M1-002,M1-008..M1-010,M1-015 | PRD §11.2–11.4 | 允许 partial write；buffer 连接级复用、不随 body 增长；至少容纳典型 TLS record；copy 可计量。 |
| M1-019 | 实现 typed half-close | StdNet | C3 | M1-015,M0-021 | TR-STREAM-006 | shutdown(Read/Write) 行为独立；不直接调用 private native handle；能力不足时依赖 UP-003。 |
| M1-020 | 实现幂等 `close`/`abort` 与等待唤醒 | StdNet | C4 | M1-008,M1-009,M1-015..M1-019 | TR-STREAM-007；PRD §11.2 | graceful/abort 区分；所有 waiter 最终退出；native dispose 最多一次；finalizer 不执行网络 cleanup。 |
| M1-021 | 实现 `StdNetTransportListener` | StdNet | C3 | M1-012,M1-015,M1-020 | PRD §10.4/§11 | accept 的 Deadline/cancel/close 唤醒、backlog、endpoint 和错误映射完整。 |
| M1-022 | 实现稳定的 `std.net` 错误映射层 | StdNet | C3 | M1-007,M1-016..M1-021 | PRD §11.3 | 不匹配 message；保留 operation phase/native code；覆盖 refused/unreachable/reset/broken pipe/timeout/cancel/closed 等。 |
| M1-023 | 实现 `TransportInfo`、endpoint 与运行时诊断 | 可观测性 | C2 | M1-006,M1-015..M1-022 | PRD §20 | 公开 transport backend、runtime IO backend、local/remote endpoint、能力；不泄漏 std.net 类型。 |
| M1-024 | 完成 Transport 确定性竞态测试 | 测试 | C4 | M1-013..M1-023 | PRD §17/§21.2 | read+close、write+abort、success+cancel、half-close、重复 close/abort、registration cleanup 全覆盖。 |
| M1-025 | 完成 Transport 泄漏、soak 与 benchmark | 性能 | C4 | M1-024 | PRD §19.1/§22 | 对比现有 std.net；达到吞吐≥95%、P95 恶化≤10%、取消 P99≤50ms；无 handle/waiter 单调增长。 |
| M1-027 | 分析并优化 background `OperationContext` 的每调用成本 | 性能 | C4 | M0-010,M1-005,M1-017,M1-018 | TR-CTX-001–005；GATE-NET-05；PRD §19.1/§22 | 按[任务说明](m1-027-background-operation-context-performance.md)先量化 context、取消/Deadline、lifecycle、operation gate 与 native I/O 的增量成本，再仅对无取消、无 Deadline 的 background 路径实施 Wirestack 内部 fast path；不得削弱取消、Deadline、同方向并发拒绝或 exactly-once；同一 `-O2` binary 的 5 payload × 11 轮正式门禁全部达到吞吐≥95%、P95 恶化≤10%，且 staging copy 保持 0。 |
| M1-026 | 六平台复跑采纳门禁并关闭 M1 | 测试 | C4 | M1-025,M1-027,UP-*（按需） | PRD M1 exit | GATE-NET-01～06 全平台通过，GATE-NET-07 移动平台通过；所有上游补丁具备回归证据。 |

---

## 5.3 M2：Resolver 与 Happy Eyeballs Connector

**目标：** 独立实现结构化解析、多地址连接、总 Deadline 和失败诊断，完全绕开现有字符串地址连接路径。

**退出条件：**

- Resolver 返回全部候选与结构化错误；
- DNS 不无限阻塞 carrier thread；
- Happy Eyeballs 在 IPv4/IPv6 blackhole、取消和竞争成功场景下无后台 candidate；
- DNS 与全部 attempt 共享单一绝对 Deadline。

| ID | 任务 | 责任域 | 复杂度 | 依赖 | PRD 追踪 | 合并/验收条件 |
|---|---|---|---:|---|---|---|
| M2-001 | 实现 HostName、IP、SocketEndpoint 与规范化规则 | Core | C3 | M1-001 | PRD §12/§16 | DNS 名、IPv4、IPv6、zone、port 分型；拒绝歧义与非法 authority；不执行隐式 DNS。 |
| M2-002 | 定义 Resolver/ResolveResult/ResolveError 契约 | Resolver | C3 | M1-005,M1-007,M2-001 | DNS-001–003 | 结果包含全部地址、family、canonical host、source、可选 expiration、diagnostics；无 TTL 时不伪造。 |
| M2-003 | 实现 resolver backend 调度与有界阻塞兜底 | Resolver | C4 | M0-013,M2-002 | DNS-004 | 优先 runtime/platform async；必要时使用有界 pool，队列/线程/取消均有上限和指标。 |
| M2-004 | 实现 Windows SystemResolver | 平台 | C3 | M2-002,M2-003 | DNS-001–004 | 结构化错误、全部候选、取消/Deadline、无 carrier 无限阻塞；平台集成测试通过。 |
| M2-005 | 实现 Linux glibc SystemResolver | 平台 | C3 | M2-002,M2-003 | DNS-001–004；ADR-0004 | native glibc 通过；不假造 TTL；错误稳定映射。musl 由 P1-011 采纳。 |
| M2-006 | 实现 macOS/iOS SystemResolver | 平台 | C3 | M2-002,M2-003 | DNS-001–004 | macOS/iOS 原生路径通过；支持应用取消和网络变化后的新解析。 |
| M2-007 | 实现 Android SystemResolver | 平台 | C3 | M2-002,M2-003 | DNS-001–004 | 真机高并发解析不拖死调度器；网络切换后新查询使用当前网络。 |
| M2-008 | 实现 HarmonyOS/OHOS SystemResolver | 平台 | C3 | M2-002,M2-003 | DNS-001–004 | 真机/原生环境通过，错误和取消语义与其他平台一致。 |
| M2-009 | 实现解析结果规范化、去重、诊断与 trace 事件 | Resolver | C2 | M2-002,M2-004..M2-008 | PRD §12.1/§20 | 保持 family 和原始证据；只做规范化/去重，不静默丢弃候选；DnsStarted/Completed 可观测。 |
| M2-010 | 定义连接 Route 与 proxy-ready 模型 | Connector | C3 | M2-001,M2-002 | CONN-005；PRD §15.2/§15.5 | 表达 direct/proxy、origin/proxy DNS、network binding、ALPN/TLS 后续参数；此阶段不实现系统代理。 |
| M2-011 | 实现 RFC 8305 风格候选交错与 attempt plan | Connector | C3 | M2-002,M2-009 | CONN-001/002 | 可配置 attemptDelay；地址 family 交错稳定、可测试；保留每个候选诊断。 |
| M2-012 | 实现多 attempt Happy Eyeballs 调度器 | Connector | C4 | M1-016,M2-010,M2-011 | CONN-002–005 | 首个成功者原子胜出；所有 loser close；取消后成功者不返回；无后台连接。 |
| M2-013 | 实现共享 Deadline、取消和 multi-attempt diagnostics | Connector | C3 | M1-005,M1-006,M2-012 | CONN-003/004 | DNS+全部 attempts 只消费父预算；记录 start/end/error/winner/cancel reason；completion exactly-once。 |
| M2-014 | 完成 scripted resolver/connector 确定性测试 | 测试 | C3 | M1-014,M2-013 | PRD §21.2 | 覆盖 IPv6 先成功/blackhole、IPv4 fallback、同时成功、全部失败、success+cancel、deadline 边界。 |
| M2-015 | 完成真机/网络模拟 blackhole 集成测试 | 测试 | C4 | M2-004..M2-014 | PRD M2 exit/§22 | 覆盖 IPv6 available/blackhole、20/100ms RTT、1% loss；loser 无泄漏，总时限不随候选数放大。 |
| M2-016 | 建立 DNS-to-connected 与 attempt 指标 benchmark | 性能 | C3 | M2-015 | PRD §22 | 输出 DNS、首 attempt、winner、总连接时长、连接数、取消延迟；作为后续 HTTP baseline。 |

---

## 5.4 M3：TLS Core 与桌面平台

**目标：** 集成单一可移植 TLS Engine，完成 TLS 1.2/1.3 client/server、信任、身份、会话、关闭和桌面平台适配；默认产物不依赖系统 OpenSSL。

**退出条件：**

- Linux/Windows/macOS TLS 1.2/1.3 client/server、ALPN/SNI、mTLS、session resumption 通过；
- 系统/自定义 trust、reference identity、不可导出私钥路径可用；
- TLS truncation 与 close_notify 证据正确；
- 互操作、fuzz、安全向量和性能门槛通过；
- 默认产物动态依赖扫描无系统 OpenSSL。

| ID | 任务 | 责任域 | 复杂度 | 依赖 | PRD 追踪 | 合并/验收条件 |
|---|---|---|---:|---|---|---|
| M3-001 | 锁定并集成 TLS provider 源码/二进制构建 | TLS | C4 | M0-020,M1-001 | TLS-PROV-003/004；PRD §23 | 版本、补丁、构建参数锁定；六平台 target 可构建；不运行时探测或 fallback 系统 OpenSSL。 |
| M3-002 | 实现内部 TLS provider SPI 与 build manifest | TLS | C3 | M3-001 | TLS-PROV-001–004 | provider 为实例；公共 API 无 native 类型；manifest 输出 providerId/version/fingerprint/backend/capability/patch level。 |
| M3-003 | 实现跨平台安全随机适配 | 平台 | C3 | M3-002 | PRD §13/§18 | 只使用平台/provider 审核过的 CSPRNG；失败结构化；随机字节与 secret 不记录日志。 |
| M3-004 | 实现 TLS Engine 外部字节流 pump | TLS | C4 | M1-010,M1-013,M3-002 | PRD §13.2/§13.7 | provider 只通过 Transport 读写；正确处理 WANT_READ/WANT_WRITE、partial I/O、Deadline、cancel 和背压。 |
| M3-005 | 实现 `TlsConnection` 生命周期状态机与所有权转移 | TLS | C4 | M1-009,M3-004 | PRD §13.7–13.9/§17 | 握手成功后独占 transport；一读一写；失败/超时 abort；close/abort 幂等；终态资源只释放一次。 |
| M3-006 | 实现 `TlsClientContext`/`TlsServerContext` builder | TLS | C3 | M3-002 | PRD §13.3 | 构造后不可变、可并发共享；在 build 时校验版本、ALPN、trust、identity、capability，不延迟到握手。 |
| M3-007 | 实现 Compatible/Modern/StrictTls13 安全档位 | TLS | C2 | M3-006 | PRD §13.4 | 默认最低 TLS1.2、优先1.3；禁用 compression/renegotiation/NULL/anonymous/0-RTT；不接受 OpenSSL cipher string。 |
| M3-008 | 实现 capability 查询与不支持能力早失败 | TLS | C2 | M3-002,M3-006 | PRD §14.3 | systemTrust/customRoots/hardwareKeys/clientCert/server/tls12/tls13/http2/networkBinding 可查询；不支持在 context build 时失败。 |
| M3-009 | 定义 TrustPolicy 与验证证据模型 | TLS | C3 | M3-006 | PRD §13.5 | 支持 System/CustomRoots/SystemPlusCustomRoots/PinnedPublicKeys；普通 API 无 TrustAll；返回可诊断验证证据。 |
| M3-010 | 实现证书链输入模型、解析边界与资源上限 | TLS | C3 | M3-009,M0-018 | PRD §13.5/§18 | 限制链长、单证书/总字节、扩展解析；错误不泄漏 provider 类型；异常输入可 fuzz。 |
| M3-011 | 实现 reference identity/hostname verifier | 安全 | C4 | M2-001,M3-010 | PRD §13.5 | SAN-only；DNS/IP 分开；不回退 CN；wildcard/IDNA/边界向量通过；SNI 与 reference identity 分开建模。 |
| M3-012 | 实现 CustomRoots/SystemPlusCustomRoots 与 pinning | TLS | C3 | M3-009..M3-011 | PRD §13.5 | 自定义 CA 不关闭 identity 验证；pin 作用域和算法明确；trust context identity 可用于 session/pool 隔离。 |
| M3-013 | 实现 Linux glibc system trust adapter | 平台 | C4 | M3-009..M3-012 | PRD §14.2/§28；ADR-0004 | 冻结 CA bundle/dir 规则；native glibc 通过；无 silent fallback；平台证据和错误稳定。musl 由 P1-011 采纳。 |
| M3-014 | 实现 Windows system trust adapter | 平台 | C4 | M3-009..M3-012 | PRD §14.2 | 使用系统证书链与策略；返回 identity/chain 证据；不导出 native provider 对象。 |
| M3-015 | 实现 macOS system trust adapter | 平台 | C4 | M3-009..M3-012 | PRD §14.2 | 使用系统信任评估；行为、错误、证据与统一模型对齐。 |
| M3-016 | 定义 `LocalIdentity`/opaque `PrivateKeyRef`/signer 契约 | TLS | C3 | M3-006,M0-018 | PRD §13.6 | 支持 PKCS#8、系统 handle/alias、external signer；TLS engine 不强制导出私钥；用户异常不跨 C ABI。 |
| M3-017 | 实现 PKCS#8/文件私钥身份 | TLS | C3 | M3-010,M3-016 | PRD §13.6 | 证书链与私钥匹配在 context build 时校验；secret 清理与错误映射明确。 |
| M3-018 | 实现通用 external signer bridge | TLS | C4 | M3-002,M3-016 | PRD §13.2/§13.6 | 签名算法协商、异步/同步边界、取消、错误与回调生命周期安全；不持全局锁调用用户代码。 |
| M3-019 | 实现 Windows 不可导出 key handle | 平台 | C4 | M3-014,M3-018 | PRD §13.6/§14.2 | 系统 key handle 可完成 client/server 签名；私钥不导出；错误和取消稳定。 |
| M3-020 | 实现 macOS Keychain/SecKey 身份 | 平台 | C4 | M3-015,M3-018 | PRD §13.6/§14.2 | SecKey 签名桥通过；私钥不导出；生命周期与线程/回调安全。 |
| M3-021 | 实现 TLS client handshake 与结果模型 | TLS | C4 | M3-004..M3-012 | PRD §13.7 | 输出版本、cipher、ALPN、peer chain、verified identity、resumed、provider info；失败/取消/超时 abort transport。 |
| M3-022 | 实现 TLS server handshake、SNI 与证书选择 | TLS | C4 | M3-004..M3-008,M3-016..M3-020 | PRD §6.3/§13.7 | 按 SNI 选择不可变 context/identity；callback 不持全局锁；无匹配时返回稳定错误。 |
| M3-023 | 实现 ALPN 与 no-shared-ALPN 语义 | TLS | C2 | M3-006,M3-021,M3-022 | PRD §13.1/§16.2 | client/server 协商次序稳定；结果进入 handshake info；HTTP 层只读取统一类型。 |
| M3-024 | 实现 mTLS client/server 验证 | TLS | C4 | M3-009..M3-023 | PRD §13.5/§13.6 | Required/Optional/None 行为明确；client identity 进入 session/pool 隔离；错误区分 required/key/trust。 |
| M3-025 | 实现有界 TLS session store 与 resumption | TLS | C4 | M3-021..M3-024 | PRD §13.9 | TLS1.2 session/TLS1.3 ticket；按 server identity、ALPN、trust、client identity、provider 隔离；有界、过期、无0-RTT。 |
| M3-026 | 实现 `close_notify`、truncation evidence 与 TLS abort | TLS | C4 | M3-005,M3-021,M3-022 | PRD §13.8 | graceful close 在 Deadline 内发送/处理 close_notify；peer TCP EOF 无 close_notify 保留证据；最终总释放资源。 |
| M3-027 | 实现 TLS 结构化错误与 runtime info | 可观测性 | C3 | M1-007,M3-002..M3-026 | PRD §16.2/§20 | 覆盖协议、版本、cipher、ALPN、证书、identity、key、alert、truncation、provider；phase/重试性稳定。 |
| M3-028 | 完成 TLS 确定性、互操作、fuzz、依赖扫描与 benchmark | 测试 | C4 | M3-001..M3-027 | PRD §19.2/§21/§22/§23 | 协议向量、主机名、session、close、truncated、外部实现互操作、fuzz 无崩溃；吞吐/握手/内存达标；无系统 OpenSSL 依赖。 |

---

## 5.5 M4：Android、iOS、HarmonyOS 平台适配

**目标：** 补齐移动和 Harmony 平台的系统信任、不可导出密钥、HTTPS client、前台 listener 与网络/生命周期验证。

**退出条件：**

- 三平台 HTTPS client 完整通过；
- 系统 CA、自定义 CA、不可导出 key 通过；
- 前后台、切网、飞行模式和取消无泄漏；
- 真机 CI 能执行发布门禁。

| ID | 任务 | 责任域 | 复杂度 | 依赖 | PRD 追踪 | 合并/验收条件 |
|---|---|---|---:|---|---|---|
| M4-001 | 实现 Android system/app trust adapter | 平台 | C4 | M3-009..M3-012,M2-007 | PRD §14.2 | 系统和应用 trust 配置可用；reference identity 不被关闭；结果映射统一。 |
| M4-002 | 实现 Android Keystore external signer | 平台 | C4 | M3-016,M3-018 | PRD §13.6/§14.2 | alias/key handle 可签名且不可导出；算法、取消、生命周期和错误通过真机测试。 |
| M4-003 | 完成 Android TLS/HTTPS client 集成 | 平台 | C4 | M4-001,M4-002,M3-021..M3-027 | PRD M4 | TLS1.2/1.3、ALPN、system/custom trust、mTLS、session 在真机通过。 |
| M4-004 | 完成 Android 前后台与网络切换验证 | 平台 | C4 | M4-003,M0-012 | GATE-NET-07 | 页面退出取消、Wi-Fi/蜂窝/飞行模式/休眠恢复可诊断；旧连接与 network binding 无泄漏。 |
| M4-005 | 实现 iOS system trust adapter | 平台 | C4 | M3-009..M3-012,M2-006 | PRD §14.2 | 系统 trust 与自定义 roots 组合行为明确；identity 证据统一。 |
| M4-006 | 实现 iOS Keychain/SecKey signer | 平台 | C4 | M3-016,M3-018 | PRD §13.6/§14.2 | 不可导出 key 完成签名；回调、取消、线程和生命周期安全。 |
| M4-007 | 完成 iOS TLS/HTTPS client 集成 | 平台 | C4 | M4-005,M4-006,M3-021..M3-027 | PRD M4 | TLS1.2/1.3、ALPN、trust、mTLS、session 在真机通过。 |
| M4-008 | 完成 iOS 前后台与网络切换验证 | 平台 | C4 | M4-007,M0-012 | GATE-NET-07 | 应用生命周期、Wi-Fi/蜂窝/飞行模式、cancel/Deadline 无泄漏且错误可诊断。 |
| M4-009 | 实现 HarmonyOS/OHOS system trust adapter | 平台 | C4 | M3-009..M3-012,M2-008 | PRD §14.2 | 系统 trust、自定义 roots、reference identity 和结构化证据在真机通过。 |
| M4-010 | 实现 Harmony system key external signer | 平台 | C4 | M3-016,M3-018 | PRD §13.6/§14.2 | 不可导出 key handle 完成签名；错误、取消、生命周期一致。 |
| M4-011 | 完成 Harmony TLS/HTTPS client/server 集成 | 平台 | C4 | M4-009,M4-010,M3-021..M3-027 | PRD §14.2/M4 | client P0 和 server P0 均通过；ALPN/SNI/mTLS/session 可用。 |
| M4-012 | 完成 Harmony 网络切换与生命周期验证 | 平台 | C4 | M4-011,M0-012 | GATE-NET-07 | 断网/恢复、切网、前后台、休眠无旧绑定泄漏；新连接可重新解析选路。 |
| M4-013 | 实现 Android/iOS 前台基础 `TlsListener` 能力 | 平台 | C4 | M1-021,M3-022,M4-003,M4-007 | PRD §4 G-003/§14.2 | 明确前台限制；accept/cancel/close/SNI 基础测试通过；不宣称后台常驻能力。 |
| M4-014 | 建立三平台真机 CI 与 capability matrix | 基础设施 | C4 | M4-003..M4-013 | PRD §14.3/§21.5 | 每次发布可运行 client、key、trust、network-change、listener 门禁；输出只读能力矩阵。 |

---

## 5.6 M5：HTTP/1.1、客户端基础设施与服务端

**目标：** 在统一 Transport/TLS 上实现严格 HTTP/1.1、流式 body、连接池、代理、重定向、重试和 client/server 生命周期。

**退出条件：**

- HTTP/1.1 client/server、streaming body、pool、CONNECT、redirect/retry、graceful shutdown 完成；
- framing、smuggling、body backpressure 和连接归还不变量通过；
- conformance、fuzz、安全 corpus 和性能门槛通过。

| ID | 任务 | 责任域 | 复杂度 | 依赖 | PRD 追踪 | 合并/验收条件 |
|---|---|---|---:|---|---|---|
| M5-001 | 创建 HTTP 公共模型与内部协议包骨架 | HTTP | C3 | M1-001,M3-006 | PRD §15.1 | HttpClient/Server/Request/Response/Headers/Method/Version/Body/Trailer 类型边界清晰；不暴露 std.net/provider 类型。 |
| M5-002 | 实现 URL/authority 解析与规范化 | HTTP | C4 | M2-001 | PRD §15.2/§21.4 | scheme/host/port/IPv6/userinfo/path/query 边界严格；CRLF/非法 authority 被拒绝；可 fuzz。 |
| M5-003 | 实现 `HttpHeaders` 多值与安全校验 | HTTP | C3 | M5-001 | PRD §15.1 | 大小写不敏感、多值保留、顺序可控；拒绝 CR/LF；单行/总大小有限；非普通 Map 唯一模型。 |
| M5-004 | 实现流式 RequestBody/ResponseBody 抽象 | HTTP | C4 | M1-005,M1-010,M5-001 | PRD §15.1 | 支持 Empty/Bytes/String/File/ReplayableFactory/OneShot；读取、关闭、取消和 backpressure 明确；不全量缓冲。 |
| M5-005 | 实现 body replayability 与提交状态模型 | HTTP | C3 | M5-004 | PRD §15.3/§15.4 | 能判断是否可重放、是否已写出、是否已向用户提交响应；为 retry/redirect 提供不可变证据。 |
| M5-006 | 实现统一 HTTP limits 配置 | HTTP | C2 | M5-001,M5-003,M5-004 | PRD §15/§18 | header line/total、body、chunk、trailer、连接/并发/队列限制有默认值且不可无界。 |
| M5-007 | 冻结 HTTP/1.1 共享 framing 规则 | HTTP | C4 | M5-003,M5-006 | PRD §15.6 | parser/serializer 共用 CL/TE/connection-close/HEAD/CONNECT/1xx 规则；冲突 CL、歧义 TE、obs-fold 一律拒绝。 |
| M5-008 | 实现 HTTP/1.1 request serializer | HTTP | C3 | M5-002..M5-007 | PRD §15.6 | 正确生成 request-line、Host、CL/chunked、trailers；防 header injection；支持 partial write/Deadline。 |
| M5-009 | 实现 HTTP/1.1 response parser | HTTP | C4 | M5-003,M5-006,M5-007 | PRD §15.6 | 增量解析 status/header/framing；处理 1xx、HEAD、CONNECT、close framing；错误带 phase。 |
| M5-010 | 实现 HTTP/1.1 server request parser | HTTP | C4 | M5-002,M5-003,M5-006,M5-007 | PRD §15.6 | 增量 request-line/header/body framing；安全规则与 client response parser 一致。 |
| M5-011 | 实现 HTTP/1.1 response serializer | HTTP | C3 | M5-003..M5-007 | PRD §15.6 | status/header/body framing、HEAD/1xx/close/chunked 正确；不产生歧义报文。 |
| M5-012 | 实现 chunked codec、trailers 与边界错误 | HTTP | C4 | M5-007..M5-011 | PRD §15.6 | chunk extension、size、terminator、trailer 增量处理；所有长度/数量有界；可 fuzz。 |
| M5-013 | 实现 1xx 与 `100-continue` 状态机 | HTTP | C3 | M5-008..M5-012 | PRD §15.6 | client/server 对 interim response 和 body 提交时机一致；超时/拒绝不误重放。 |
| M5-014 | 实现 CONNECT 与 Upgrade 的 HTTP/1.1 边界 | HTTP | C3 | M5-007..M5-013 | PRD §15.6 | CONNECT 成功后准确转交剩余 transport；Upgrade 不污染连接池；失败保持 HTTP 语义。 |
| M5-015 | 建立 request-smuggling 防护 corpus 与差分测试 | 安全 | C4 | M5-007..M5-014 | PRD §15.6/§21.3 | 覆盖 CL/CL、TE/CL、非法 chunk、obs-fold、空白、代理差异；parser/serializer 无歧义。 |
| M5-016 | 实现 HTTP/1.1 连接生命周期对象 | HTTP | C4 | M3-005,M5-008..M5-014 | PRD §15.2/§17 | 一次请求在无 pipelining 前提下串行；body 完成前不复用；EOF/abort/close 分类正确。 |
| M5-017 | 实现完整连接池 key | HTTP | C3 | M2-010,M3-009,M3-016,M5-001 | PRD §15.2 | 包含 scheme/origin/proxy/network/TLS context/trust/client identity/provider/ALPN；相等性与 hash 单测完整。 |
| M5-018 | 实现有界连接池、acquire/release/eviction | HTTP | C4 | M5-016,M5-017 | PRD §15.2/§16.3 | 总连接、每 key、idle、waiter 有界；pool wait 支持 Deadline/cancel；坏连接不返池。 |
| M5-019 | 实现 ResponseBody 所有权、close/drain 与返池协议 | HTTP | C4 | M5-004,M5-016,M5-018 | PRD §15.2/§17 | 未消费或未显式 close 不返池；drain 有上限/Deadline；完成与池归还 exactly-once。 |
| M5-020 | 实现 `HttpClient` 端到端请求流水线 | HTTP | C4 | M2-013,M3-021,M5-002..M5-019 | PRD §15.2 | URL→route→DNS→HE→CONNECT→TLS→ALPN→HTTP1；全部阶段共享 OperationContext；trace 事件完整。 |
| M5-021 | 实现显式 HTTP proxy、origin/proxy 独立 DNS 与 `NO_PROXY` | HTTP | C4 | M2-010,M5-020 | PRD §15.5 | direct/proxy 选择、IPv4/IPv6 proxy、NO_PROXY 匹配明确；不实现 PAC/WPAD。 |
| M5-022 | 实现 HTTPS CONNECT tunnel 与 proxy auth hook | HTTP | C4 | M5-014,M5-021 | PRD §15.5 | CONNECT 后再 TLS；认证 hook 不泄漏凭据；proxy/origin 错误 phase 区分。 |
| M5-023 | 实现重定向策略 | HTTP | C3 | M5-005,M5-020 | PRD §15.4 | 最大次数、跨 origin 敏感 header、HTTPS→HTTP、301/302/303、307/308 重放规则正确。 |
| M5-024 | 实现 retry policy 与错误可重试判定 | HTTP | C4 | M1-007,M5-005,M5-020 | PRD §15.3 | 仅幂等/显式安全+可重放+未提交+总 Deadline 内+策略允许时重试；不捕获通用异常盲发。 |
| M5-025 | 实现 `HttpServer` builder、listener 与 TLS/ALPN 接入 | HTTP | C4 | M1-021,M3-022,M5-001,M5-010,M5-011 | PRD §15.8 | 支持明文 H1、TLS H1；listener/limits/handler/context 不泄漏底层类型。 |
| M5-026 | 实现服务端连接、请求与 handler 生命周期 | HTTP | C4 | M5-016,M5-025 | PRD §15.8/§17 | per-client 并发、idle timeout、body backpressure、handler 异常、connection close/abort 有界且可诊断。 |
| M5-027 | 实现 HTTP 服务端 graceful shutdown | HTTP | C3 | M5-025,M5-026 | PRD §15.8 | 停止 accept、不接新 request、等待 in-flight 到 Deadline、abort 剩余；幂等且 waiter 全退出。 |
| M5-028 | 实现 HTTP 结构化错误与网络事件 | 可观测性 | C3 | M1-006,M1-007,M5-020..M5-027 | PRD §16.3/§20 | InvalidUrl/framing/proxy/pool/redirect/replay/overload 等稳定映射；事件默认不含 header/body secret。 |
| M5-029 | 完成 HTTP/1.1 conformance、fuzz、smuggling 与竞态测试 | 测试 | C4 | M5-001..M5-028 | PRD §21 | parser/chunked/URL/proxy fuzz；response close+pool return、cancel、partial I/O、graceful shutdown race 全覆盖。 |
| M5-030 | 完成 HTTP/1.1 client/server benchmark 与文档样例 | 性能 | C4 | M5-029 | PRD §19.3/§22/§29 | keep-alive 小请求吞吐≥当前 stdx 基线90%；流式大 body 内存不线性增长；提供 client/server/CONNECT/mTLS 示例。 |

---

## 5.7 M6：HTTP/2

**目标：** 实现有界 HPACK、帧层、连接/stream 状态机、流控、多路复用、取消、GOAWAY 和 client/server/pool 集成。

**退出条件：**

- HTTP/2 client/server conformance 通过；
- 100 stream benchmark 达标；
- stream cancel 不关闭整连接；
- 公共 server facade 按 TLS ALPN 在 H2/H1 间确定性 dispatch；
- request/connection/stream 取消有公开、分型、幂等的控制 handle；
- SSE/无限累计 response 在 H1/H2 下保持有界内存并可及时取消；
- frame、header table、write queue、window 和 stream 数全部有界。

| ID | 任务 | 责任域 | 复杂度 | 依赖 | PRD 追踪 | 合并/验收条件 |
|---|---|---|---:|---|---|---|
| M6-001 | 定义 HTTP/2 frame/setting/error 公共内部模型 | HTTP2 | C3 | M5-001,M5-006 | PRD §15.7 | frame type、flags、stream id、error code 分型；长度和保留位校验规则冻结。 |
| M6-002 | 实现增量 frame parser/serializer | HTTP2 | C4 | M6-001,M1-002 | PRD §15.7 | 支持 SETTINGS/HEADERS/DATA/CONTINUATION/WINDOW_UPDATE/RST/GOAWAY/PING；partial I/O 和 frame size 上限正确。 |
| M6-003 | 实现 SETTINGS 协商与生效时序 | HTTP2 | C3 | M6-002 | PRD §15.7 | ACK、初始窗口、max frame/header table/concurrent streams 等按协议生效；非法设置报 connection error。 |
| M6-004 | 实现 HPACK 整数、字符串与静态表 | HTTP2 | C3 | M6-001 | PRD §15.7/§21.3 | RFC 向量通过；整数溢出、长度和索引越界被拒绝。 |
| M6-005 | 实现 HPACK Huffman 编解码 | HTTP2 | C4 | M6-004 | PRD §15.7 | RFC 向量、EOS/padding/invalid code 处理正确；可 fuzz；不产生无界临时分配。 |
| M6-006 | 实现 HPACK 动态表与内存上限 | HTTP2 | C4 | M6-003..M6-005 | PRD §15.7/§18 | table update、eviction、sensitive/no-index、peer limit 正确；内存严格有界。 |
| M6-007 | 实现 header block、CONTINUATION 与 header list 限制 | HTTP2 | C4 | M6-002,M6-006 | PRD §15.7 | 跨 frame header block 状态严格；不允许交错；header list/table/fragment 有界。 |
| M6-008 | 实现 HTTP/2 connection 状态机 | HTTP2 | C4 | M6-002,M6-003,M6-007 | PRD §15.7/§17 | preface、open/draining/closed、connection error、GOAWAY 边界明确；completion exactly-once。 |
| M6-009 | 实现每连接单 reader loop | HTTP2 | C4 | M1-010,M6-008 | PRD §15.7 | 所有入站 frame 串行解码并分派；无每 stream OS 线程；reader 终止唤醒所有 stream。 |
| M6-010 | 实现有界 write scheduler | HTTP2 | C4 | M6-008 | PRD §15.7 | 控制帧/数据帧调度、partial write、队列上限、cancel/close、公平性可测试；仅一个 writer。 |
| M6-011 | 实现 stream 状态机与生命周期 | HTTP2 | C4 | M6-008..M6-010 | PRD §15.7/§17 | idle/open/half-closed/closed 转移、stream id、并发上限、终态清理正确。 |
| M6-012 | 实现 connection/stream flow control | HTTP2 | C4 | M6-003,M6-011 | PRD §15.7 | 发送/接收窗口、WINDOW_UPDATE、溢出、backpressure 正确；不形成无界 buffering。 |
| M6-013 | 实现 HTTP/2 client request/response 映射 | HTTP2 | C4 | M5-002..M5-006,M6-007..M6-012 | PRD §15.7 | pseudo-header、普通 header、body/trailer、status 映射严格；非法组合被拒绝。 |
| M6-014 | 实现 HTTP/2 server request/response 映射 | HTTP2 | C4 | M5-025,M6-007..M6-012 | PRD §15.7/§15.8 | server handler 与 stream 生命周期、backpressure、limits、trailers 对接正确。 |
| M6-015 | 实现 stream cancellation 与 `RST_STREAM` | HTTP2 | C3 | M6-011..M6-014 | PRD §15.7 | 单 stream cancel 发送/处理 RST_STREAM，不默认关闭连接，不影响其他 stream；资源及时释放。 |
| M6-016 | 实现 GOAWAY、draining 与策略重试证据 | HTTP2 | C4 | M5-005,M5-024,M6-008..M6-015 | PRD §15.7 | GOAWAY 后不创建新 stream；区分可能未处理请求；仅幂等且可重放请求进入策略重试。 |
| M6-017 | 实现 PING、idle/health 与连接关闭 | HTTP2 | C3 | M6-008..M6-010 | PRD §15.7 | PING ACK、idle 检测、graceful/abort 与 Deadline 正确；不得产生无界定时器。 |
| M6-018 | 集成 ALPN、连接池与多路复用容量 | HTTP2 | C4 | M3-023,M5-017..M5-020,M6-013,M6-016 | PRD §15.2/§15.7 | h2 优先并回退 H1；pool 按连接 stream 容量分配；GOAWAY/draining 连接不接新请求。 |
| M6-019 | 完成 HTTP/2 conformance、竞态与 fuzz | 测试 | C4 | M6-001..M6-018 | PRD §21.2–21.4 | HPACK vectors、flow control、invalid order、CONTINUATION、RST、GOAWAY、limit fuzz；RST+GOAWAY race 覆盖。 |
| M6-020 | 完成 HTTP/2 1/10/100 stream benchmark 与文档 | 性能 | C4 | M6-019 | PRD §19.3/§22 | 记录 req/s、P50/P95/P99、连接数、RSS、队列、flow-control stall；100 并发显著减少 TCP/TLS 连接数。 |
| M6-021 | 实现 HTTP/2 server facade、ALPN dispatch 与端到端验收 | HTTP2 | C4 | M3-023,M5-025..M5-027,M6-014..M6-019 | PRD §15.7–15.8/§21 | 同一公共 `HttpServer` 在真实 TLS loopback 上只依据已协商 ALPN 分派 `h2`/`http/1.1`；H2 request/body/trailer/response、并发限制、GOAWAY graceful shutdown 与结构化错误端到端通过；无协商协议稳定失败；公共 API 不暴露内部 H2/TLS 类型。 |
| M6-022 | 公开 request/connection/stream cancellation handle | API | C4 | M5-020,M5-025..M5-027,M6-015,M6-018,M6-021 | PRD §10.2/§15.1–15.2/§15.7/§17 | 公共 handle 明确 request、connection、stream 作用域且 `cancel` 幂等；request cancel 覆盖 DNS→body 全路径，H1 connection cancel 唤醒并终止所属请求，H2 stream cancel 只发该流 RST 且不影响 sibling，H2 connection cancel 唤醒全部流；成功/EOF/close/cancel/GOAWAY 竞态 exactly-once 且 registration、waiter、buffer 及时释放。 |
| M6-023 | 完成 SSE/无限累计 streaming profile | 可靠性 | C4 | M5-004,M5-020,M6-018,M6-021,M6-022 | PRD §15.1–15.2/§15.7/§19.3/§22 | 真实 H1/H2 `text/event-stream` 各连续运行至少 1 小时且消费不少于 1,000,000 个带序号事件；不全量累计，应用/协议队列、flow-control、RSS 与 heavy-GC heap 在预热后保持显式上限/稳态；slow consumer 触发背压而非增长，公开 cancel 在预算内退出，H2 sibling stream 不受影响；保留原始样本、环境和 PASS/FAIL 报告，不要求重复 24h soak。 |
| M6-024 | 消除 connection window 耗尽时的 sibling starvation | HTTP2/可靠性 | C4 | M6-010,M6-012,M6-019,M6-021,M6-022 | PRD §15.7/§19.3/§22 | 在真实 TLS loopback 上，256 KiB 慢流占满 65,535-byte connection window 且 client 仅消费 4 KiB 后，不 cancel/close 该流，随后 1/10/100 个 2-byte sibling 均在各自单调绝对 Deadline 内完成；DATA 调度和 coalesced WINDOW_UPDATE 保证所有 ready stream 有界进展，且控制帧数、write queue、window、body buffer 保持现有上限；保留 pre-fix FAIL、post-fix raw latency/flow-control stall 和 100-run race evidence；Linux 原生通过只关闭 Linux cell，公共 API 不变。 |
| M6-025 | 修复 `wirestack.http` facade 并发回归和失败后不退出 | HTTP2/可靠性 | C4 | M6-021..M6-024 | PRD §15.7–15.8/§17/§21.3 | 在原生 Linux 上保留全包串行复现的首个异常、活动 task、连接、stream、waiter 和进程终态证据；修复产品生命周期或测试清理的实际根因，不过滤用例、不提高 5 秒请求 Deadline、不新增 timeout owner；三个相关 facade 用例按原顺序连续运行 100 轮且零失败、零超时、零残留资源，`src/http` 非 Performance 全包和 `scripts/check` 均在硬上限内退出 0。 |

---

## 5.8 M7：稳定版硬化、交付与迁移

**目标：** 完成全平台 release gate、安全审查、SBOM、签名、API freeze、迁移文档、soak/fuzz/性能报告和稳定版验收。

**退出条件：**

- 所有 P0 与发布验收项均有自动或人工证据；
- 无未修复 High/Critical；
- 六平台 release artifact 与真机/原生 VM gate 通过；
- 默认产物报告 `externalOpenSslDependency: false`；
- API、文档、迁移和安全更新流程冻结。

| ID | 任务 | 责任域 | 复杂度 | 依赖 | PRD 追踪 | 合并/验收条件 |
|---|---|---|---:|---|---|---|
| M7-001 | 执行 P0 需求与不变量追踪审计 | 质量 | C3 | M1..M6 | PRD §17/§26 | 每个 P0、15 条生命周期不变量、22 条发布验收均映射测试/报告/代码；缺口形成阻断 issue。 |
| M7-002 | 执行最终架构依赖与私有 ABI 审计 | 架构 | C2 | M0-003,M7-001 | PRD §7.2/§26 | Core 无 std.net；公共 API 无底层类型；Wirestack 无 `CJ_MRT_Sock*`；新 HTTP/TLS 无旧 bridge/global provider。 |
| M7-003 | 执行全平台动态依赖/OpenSSL 扫描 | 发布 | C3 | M3-028,M4-014,M6-020..M6-024 | PRD §4 G-001/§23/§26 | 每个平台 artifact 生成依赖清单；默认产物不搜索/链接系统 libssl/libcrypto/OpenSSL DLL。 |
| M7-004 | 建立全平台 release CI 与真机/原生 VM 门禁 | 基础设施 | C4 | M1-026,M2-015,M3-028,M4-014,M5-030,M6-020..M6-024 | PRD §21.5/§26；ADR-0004 | Windows、Linux glibc、macOS、Android、iOS、Harmony 均完成 compile/unit/integration/native gate；仅交叉编译不算通过。 |
| M7-005 | 完成最终 24h+ soak 与资源上限报告 | 可靠性 | C4 | M7-004 | PRD §9/§17/§19 | idle/active、10k idle（目标平台）、connect/reset/cancel、H1 pool、H2 multiplex 混合；所有集合有界且无单调泄漏。 |
| M7-006 | 建立持续 fuzz 任务与发布阈值 | 安全 | C4 | M3-028,M5-029,M6-019 | PRD §18/§21.4 | TLS record/handshake/hostname/cert/H1/chunked/H2/HPACK/URL/proxy targets 持续运行；崩溃可复现并阻断发布。 |
| M7-007 | 建立性能回归基线与 CI gate | 性能 | C4 | M1-025,M2-016,M3-028,M5-030,M6-020..M6-024 | PRD §19/§22 | raw TCP/TLS/H1/H2/取消/SSE 长流/内存基线版本化；门槛自动判定，平台抖动单独记录。 |
| M7-008 | 准备独立安全审查材料 | 安全 | C3 | M0-018,M7-001..M7-007 | PRD §18/§27 | 提供 threat model、架构、provider、C ABI、parser、key/trust、fuzz、SBOM、已知限制和复现环境。 |
| M7-009 | 完成独立安全审查与修复闭环 | 安全 | C4 | M7-008 | PRD §18/§26 | 所有发现分级、复现、修复、回归；High/Critical 未关闭时 release gate 必失败。 |
| M7-010 | 生成 SBOM、provider manifest 与 build fingerprint | 发布 | C3 | M3-002,M7-003 | PRD §13.1/§18/§23 | 每个 artifact 可查询 provider/crypto/trust/capability/patch level/target/features；SBOM 与构建产物绑定。 |
| M7-011 | 实现发布 artifact 签名与验证流程 | 发布 | C3 | M7-010 | PRD §23 | 所有 release artifact、SBOM、manifest 有签名；发布和消费侧验证步骤文档化并在 CI 演练。 |
| M7-012 | 执行公共 API freeze 与兼容性检查 | API | C4 | M5-030,M6-020..M6-024,M7-001 | PRD §24/§28/§29 | 冻结包名/major/API 和公开 cancellation handle；无 global TlsKit/TrustAll/OpenSSL string/StreamingSocket/旧适配器；生成 API baseline。 |
| M7-013 | 编写迁移指南与 API mapping | 文档 | C3 | M7-012 | PRD §24.3 | 覆盖 timeout→Deadline、cancel、CA、mTLS、stream body、retry、errors、移除 OpenSSL 配置；旧新包共存边界明确。 |
| M7-014 | 完成用户与协议开发者示例 | 文档 | C3 | M5-030,M6-020..M6-024,M7-012 | PRD §6/§29 | HTTPS client、已有 transport TLS、CONNECT+TLS、H1/H2 server、SSE、mTLS、自定义 CA、分作用域取消/Deadline 示例可构建运行。 |
| M7-015 | 建立安全更新 SLA、provider 升级与回滚手册 | 发布 | C3 | M0-020,M7-010,M7-011 | PRD §18/§23/§27 | 漏洞分级、补丁窗口、版本发布、回滚、公告、SBOM 更新和兼容验证流程可演练。 |
| M7-016 | 构建六平台 release artifact 与安装验证 | 发布 | C4 | M7-003..M7-015 | PRD §23/§26 | 每个平台包可安装、运行、查询 runtime info；文档不要求安装 OpenSSL；旧 global provider 不影响新栈。 |
| M7-017 | 生成稳定版验收矩阵与发布候选报告 | 质量 | C3 | M7-001..M7-016 | PRD §26 | 22 条验收逐项给出 PASS/FAIL、证据链接、artifact digest、平台、已知限制；任一 P0 FAIL 阻断稳定版。 |

---

## 6. 条件上游任务：仅由门禁失败解锁

这些任务默认状态为 **Blocked / Do not start**。只有对应 M0 失败报告、最小接口 RFC 和回归测试计划同时存在时，才允许转为 Ready。

| ID | 条件任务 | 解锁条件 | 证据来源 | 完成条件 |
|---|---|---|---|---|
| UP-001 | 增加可取消的 runtime/`std.net` wait/wakeup 正式接口 | 仅当 GATE-NET-01/03 失败 | M0-006/M0-008 | close/cancel 能唤醒 connect/read/write/accept；exactly-once；六平台回归；Wirestack 不轮询 sleep。 |
| UP-002 | 暴露结构化 peer EOF/local close/RST/abort 终态 | 仅当 GATE-NET-04 失败 | M0-009 | 上层无需时间顺序猜测；错误/EOF 证据跨平台稳定；TLS truncation 测试可依赖。 |
| UP-003 | 增加 typed `shutdownRead`/`shutdownWrite` | 仅当 half-close 无法通过正式接口实现 | M0-009/M1-019 | 半关闭不依赖 private handle；与 concurrent read/write/close 的竞态测试通过。 |
| UP-004 | 增加 offset/length/span I/O 与 `writeSome` | 仅当 GATE-NET-05 性能或语义失败 | M0-010/M0-014 | 支持 partial I/O、减少 staging copy；raw TCP 门槛通过；保持现有 API 兼容策略明确。 |
| UP-005 | 暴露稳定 native error code/operation phase | 仅当错误无法可靠分类 | M0-006..M0-010 | 不解析 exception message；连接池/retry 可基于稳定 code；平台回归完整。 |
| UP-006 | 改进 Windows 低复制 socket buffer 路径 | 仅当 Windows copy profile 未达标 | M0-014 | 取消固定 4KiB 有效读取；copy 指标与吞吐/延迟门槛通过；不在 TLS 层叠加无界大 buffer。 |
| UP-007 | 增加 runtime-native async resolver 或正式 resolver API | 仅当 DNS 阻塞 carrier 且平台 async/有界 pool 不足 | M0-013 | 高并发解析不占满 carrier；取消/Deadline/结构化错误通过；禁止无界线程池。 |

这些 `UP-*` 任务在 Wirestack 中只保留 tracking issue、失败门禁证据与回归要求；真正的 `std.net`/runtime 修改必须在对应上游仓库单独实现和提交，不得从 Wirestack 工作树跨仓库直接提交上游改动。

条件任务合并规则：

1. 上游改造 PR 只实现门禁要求的最小正式能力，不顺带重构 `std.net`。
2. 必须先在 `std.net`/runtime 自身增加回归测试，再更新 `StdNetTransport`。
3. 禁止 Wirestack 直接访问 private handle 或 `CJ_MRT_Sock*` 作为临时绕过。
4. 合并后重跑受影响平台的 M0 门禁和 M1 transport 竞态/性能测试。

---

## 7. 稳定版之后的 P1/独立项目队列

以下项目不属于当前 P0 release critical path。除非 M0 决策显式提升优先级，否则不得插入 M1～M7 主线。

| ID | 项目 | 来源 | 进入条件 |
|---|---|---|---|
| P1-001 | Vectored I/O | TR-BUF-002 | 在不改变 P0 正确性的前提下减少 header+body/TLS record copy。 |
| P1-002 | 系统代理与 PAC | PRD §15.5/§28 | 在显式 proxy 稳定后实现；不得进入 M5 P0 关键路径。 |
| P1-003 | Cookie 可选包 | PRD §28 | 与核心 HTTP 解耦；不扩大默认敏感数据处理面。 |
| P1-004 | 内容解压可选包 | PRD §28 | 带压缩炸弹和输出上限；不在核心 parser 内隐式启用。 |
| P1-005 | FIPS 路径决策与实现 | PRD §28 | 先冻结 provider/认证边界，再决定是否提供独立构建配置。 |
| P1-006 | 用户可替换 Resolver 扩展点 | PRD §28 | 保持默认 SystemResolver；扩展点不得泄漏平台类型。 |
| P1-007 | 公开 TLS provider 插件扩展点 | PRD §28 | 仅在 provider SPI 稳定且安全审查通过后考虑；禁止全局可变 singleton。 |
| P1-008 | TLCP 阶段与 provider 归属 | PRD §28 | 作为独立协议/供应链决策，不污染 TLS1.2/1.3 基线。 |
| P1-009 | 0-RTT | PRD §5/§13.9 | 需单独重放安全模型；P0 明确关闭。 |
| P1-010 | HTTP/3/QUIC | PRD §5 | 独立项目，不复用 TCP Transport 假设；不得提前侵入本项目公共 API。 |
| P1-011 | Linux musl 采纳 | ADR-0004 | 仓颉 SDK 发布受支持的 musl target、标准库、runtime 和构建说明后启动；必须补齐 native compile/unit/integration、resolver、trust、依赖、性能和安装证据。 |

---

## 8. Bootstrap 后建议首批创建的仓库 Issue

仓库控制面初始化完成后，首批只创建能够产生架构证据或解除关键阻塞的任务：

1. M0-001 盘点现有实现与依赖图。
2. M0-002 提出 vNext 逻辑包与目录布局。
3. M0-003 建立架构依赖守卫。
4. M0-004 建立门禁测试框架。
5. M0-005 raw TCP baseline。
6. M0-006～M0-010 close/竞态/Deadline/EOF/复制门禁。
7. M0-013 DNS carrier-thread 验证。
8. M0-015 TLS provider 候选矩阵。
9. M0-016 TLS provider 六平台 PoC。
10. M0-018 threat model。

在这些任务完成前，不应创建大范围的“实现 TLS Core”“重写 HTTP Client”泛化 Issue。

---

## 9. Issue 模板

```markdown
# <ID> <标题>

## 背景与 PRD 追踪
- PRD：<章节/Requirement ID>
- 上游任务：<依赖 ID>
- 阻断的里程碑：<M0–M7>

## 范围
- ...

## 非目标
- 不复制旧 API
- 不引入新的 timeout owner
- 不调用 private runtime ABI

## 设计约束
- 依赖方向：...
- 所有权/并发/终态：...
- 资源上限：...
- 错误与可观测性：...

## 交付物
- 实现
- 单元/模型/平台测试
- benchmark/fuzz/真机证据（按需）
- 文档/ADR/API 变更（按需）

## 验收条件
- [ ] ...
- [ ] exactly-once / 幂等终态验证
- [ ] registration/timer/waiter 无泄漏
- [ ] 架构依赖守卫通过

## 证据
- 测试命令与输出：
- benchmark 环境与 baseline：
- 真机/VM/target：
- fuzz corpus/seed：
```

---

## 10. Release Gate 汇总

| Gate | 负责里程碑 | 阻断条件 |
|---|---|---|
| Architecture | M0/M7 | Core 导入 std.net；公共 API 泄漏底层类型；调用 private ABI；引用旧 OpenSSL bridge |
| Transport semantics | M0/M1 | close/cancel/EOF/half-close/exactly-once 任一不稳定 |
| Raw TCP performance | M1 | 吞吐 < 95% baseline；P95 恶化 > 10%；Windows 仍固定 4KiB |
| Resolver/Connector | M2 | carrier 无限阻塞；blackhole 失败；loser/background attempt 泄漏；Deadline 放大 |
| TLS security/interoperability | M3/M4 | TLS1.2/1.3、trust、identity、mTLS、session、close_notify 任一 P0 缺失 |
| OpenSSL independence | M3/M7 | 默认 artifact 依赖/搜索系统 OpenSSL |
| HTTP/1.1 security | M5 | framing 歧义、smuggling corpus、body ownership/pool 不变量失败 |
| HTTP/2 conformance/resource | M6 | stream cancel 影响其他流；GOAWAY/flow control 错误；任何 table/queue/window 无界 |
| Native platform | M4/M7 | 仅交叉编译、无真机/原生 VM 运行证据 |
| Fuzz/security review | M7 | 未复现崩溃；未关闭 High/Critical；审查未完成 |
| Release | M7 | 22 条发布验收任一 P0 FAIL；SBOM/manifest/signature 不完整 |

---

## 11. 任务统计

- 主线任务：**174**
- 条件上游任务：**7**
- 稳定版后 P1/独立项目：**10**
- 主线 + 条件任务总数：**181**

该数量代表 Issue/PR 级工作项，不代表必须串行执行；关键是保持里程碑退出门禁和依赖方向。
