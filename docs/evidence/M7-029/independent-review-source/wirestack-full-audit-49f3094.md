# Wirestack 全仓静态代码审计与发布就绪度报告

**审计基线：** `main@49f30940875bd76876b4b46f1b115e5a9f31fd76`  
**基线最后核对：** 2026-08-29；审计结束时 `main` 未移动。  
**审计类型：** 固定提交、全仓目录覆盖、重点生产代码逐项静态审计、测试与证据审计、发布与治理审计。  

> 执行限制：审计执行环境无法解析 `github.com`，因此不能独立完成 clone、`cjpm check/build/test` 和 native qualification。报告严格区分“静态确认”“仓库自报证据”和“仍需动态复现”。缺少独立执行不会降低静态发现的有效性，但不能把仓库中的 PASS 等同于本次独立复现。

## 1. 最终结论

**总体发布结论：NO-GO。**

Wirestack 已经不是概念原型。Linux glibc 主路径具备完整的 Transport、Resolver、Connector、TLS、HTTP/1.1、HTTP/2、client/server、proxy、streaming、cancellation 和证据体系；HTTP/1.1 parser/framing、TLS provider 边界、HTTP/2 单 reader/writer 模型和资源上限尤其扎实。

但当前固定提交仍存在：

- 2 项 Critical；
- 11 项 High；
- 22 项 Medium；
- 6 项 Low；
- 1 项功能边界 Advisory。

其中发布前必须关闭的主链是：

1. 版本库缺少标准构建所需 provider manifest；
2. CI 没有强制 clean Cangjie build/test；
3. `main` 无保护；
4. 许可、evidence freshness、24h soak、独立安全审查与签名未闭合；
5. HTTP/2 SETTINGS、server flow-control、H2 body wrapper 存在高置信度跨层正确性缺陷；
6. proxy credential 与 TLS system-trust session partition 存在安全隔离缺口。

因此当前最准确的成熟度描述是：

> **Linux-first 的高质量实现候选，具备较强自证工程，但尚不是可外部独立复现和发布的安全网络基础库；六平台仍处于目标/PoC/占位混合阶段。**

## 2. 审计范围与覆盖

| 区域 | 覆盖内容 | 深度 |
|---|---|---|
| 仓库与构建控制面 | 根目录、CJPM、build.cj、scripts、tools、GitHub Actions、branch/ruleset/release | 完整目录审计；关键脚本逐项审查 |
| 公共 HTTP API | client/server、TLS config、proxy、redirect、retry、cancellation、errors、package aliases | 关键生产文件逐项审查 |
| 公共 TLS API | context builders、facade、runtime info、listener/connection、type aliases | 关键生产文件逐项审查 |
| Transport Core | span、Deadline、OperationContext、Cancellation、Completion、lifecycle、memory/scripted transports | 生产实现与对应竞态测试抽查 |
| std.net adapter | connect/read/write/accept/close/abort、endpoint conversion、error mapping | 完整主文件审查 |
| Resolver / Connector | Cangjie backend、native pthread pool/getaddrinfo、Happy Eyeballs、route identity | 生产与 native 实现审查 |
| Trust / Identity / TLS Engine | trust policy、hostname/IP、pinning、context、identity、session、engine pump、connection | 高风险生产路径逐项审查 |
| Native TLS provider | C ABI、AWS-LC engine、certificate/key/session/external signer/SNI/close_notify | C/H 主实现分段审查 |
| HTTP/1.1 | URL/model、head parser、framing、chunked、serializer、request/response streams、pool、proxy、server | 主要生产文件逐项审查 |
| HTTP/2 | frame、settings、state machine、HPACK/Huffman、stream registry、flow、writer、GOAWAY/RST、client/server/body | 主要生产文件逐项审查 |
| 测试与证据 | 对应 unit/integration/race/fuzz/performance/soak/release evidence | 结构与关键缺口审查；未逐行复核每个 assertion |
| 跨平台目录 | linux/android/apple/windows/harmony stubs 与平台证据 | 目录与能力状态审查 |

仓库自己的 M7-021 报告记录 Linux release payload 含 88 个 production Cangjie source files；M7-020 状态材料记录扫描 188 个 Cangjie 文件和 11 个 build/native 文件。本次以固定 Git tree 建立目录清单，并对所有高风险生产子系统与跨层 ownership 边界进行审查。测试侧重点是确认断言能否覆盖发现路径，而不是逐行复核每个测试函数。

## 3. 做得正确的部分

- 架构边界清晰：HTTP/TLS Core 不直接依赖 `std.net`，provider 不拥有 socket，便于未来平台替换。
- HTTP/1.1 默认严格：精确 CRLF、拒绝 obs-fold、CL/TE 歧义、冲突 Content-Length、Host/absolute-form 分歧和非法 chunked。
- HTTP/2 采用单 reader、单 writer、独立 stream exchange/flow controller，核心并发方向正确。
- HPACK/Huffman、frame、header block、stream、queue、window、certificate、session 等多数资源都有显式硬上限。
- TLS 将 SNI、reference identity、trust、pinning、client identity、provider identity 分开建模；0-RTT、压缩、重协商等默认关闭。
- Native AWS-LC 层对输入长度、chain/session/signature 上限和敏感 buffer 清零较严谨。
- ResponseBody、OperationCompletion、TransportLifecycle 等对象有明确 exactly-once/单 owner 思路。
- 证据体系优于普通早期项目：安装后 consumer smoke、dependency scan、SBOM、性能矩阵、确定性 fuzz 和 soak 合同均已建立。

## 4. 发现项总表

| ID | 严重度 | 置信度 | 类别 | 标题 | 验证状态 |
|---|---|---|---|---|---|
| `WS-BUILD-001` | **Critical** | High | Build / reproducibility | 固定提交缺少标准构建必需的 AWS-LC provider manifest | 静态确认；未独立执行 |
| `WS-CI-001` | **Critical** | High | CI / merge gate | 通用 PR 门禁不执行完整 Cangjie clean build/test | 静态确认 |
| `WS-EVID-001` | **High** | High | Evidence integrity | 发布证据 freshness 未完整绑定 native/build 输入 | 静态确认 |
| `WS-GOV-001` | **High** | High | Repository governance | `main` 未保护且没有 required status checks / ruleset | GitHub 状态确认 |
| `WS-H2-SERVER-FLOW-001` | **High** | High | HTTP/2 flow control | server response 在 writer 入队成功前消耗 DATA send window | 静态确认 |
| `WS-H2-SETTINGS-001` | **High** | High | HTTP/2 protocol | 把本地资源上限当作 peer RFC 默认值，且未完整广告非默认 SETTINGS | 静态确认 |
| `WS-H2-WRAP-001` | **High** | High | HTTP/2 body completion | 公共 cancellation wrapper 破坏 HTTP/2 END_STREAM/trailer 完成语义 | 静态确认 |
| `WS-LIC-001` | **High** | High | Legal / release | 项目自身缺少明确 LICENSE 和正式发行许可入口 | 仓库元数据与根目录确认 |
| `WS-PROXY-001` | **High** | High | Proxy identity / pooling | HTTPS CONNECT 池键未包含代理认证身份 | 静态确认 |
| `WS-RES-001` | **High** | Medium-High | Resolver availability | 活动 `getaddrinfo` 无法取消，resolver close 的完成时间依赖外部 NSS/DNS 返回 | 静态确认；系统行为依赖平台 |
| `WS-RETRY-001` | **High** | Medium-High | HTTP retry / commit evidence | 写超时可能在未知物理提交状态下被标为可重试 | 静态路径确认；需故障注入复现 |
| `WS-STDNET-001` | **High** | High | Transport lifecycle | 取消单次 `accept` 会永久关闭整个 listener | 静态确认 |
| `WS-TLS-TRUST-001` | **High** | High | TLS trust / session resumption | 系统信任变化不会可靠改变 TLS session partition | 静态确认 |
| `WS-API-001` | **Medium** | High | Transport API | `ByteSpan` 宣称 immutable，却公开可变 `Array<Byte>` backing | 静态确认 |
| `WS-API-ALIAS-001` | **Medium** | High | Public API / ABI | 公共 package 通过 type alias 绑定 internal 类型身份 | 静态确认 |
| `WS-CANCEL-001` | **Medium** | High | Cancellation resources | 公共 cancellation callback registry 无硬上限 | 静态确认 |
| `WS-CI-SUPPLY-001` | **Medium** | High | CI supply chain | 安全/发布工作流依赖 mutable action tags 和滚动环境 | 静态确认 |
| `WS-CONN-001` | **Medium** | High | Connector resources | Happy Eyeballs 为全部 candidate 立即 spawn task | 静态确认 |
| `WS-H2-BODY-001` | **Medium** | High | HTTP/2 diagnostics | 未知 Content-Length 响应的 `bodyBytes` 统计始终为零 | 静态确认 |
| `WS-H2-BUFFER-001` | **Medium** | High | HTTP/2 buffering | 入站 body queue 复用 outbound `maxPendingWrites` 且无独立 byte cap | 静态确认 |
| `WS-H2-DRAIN-001` | **Medium** | Medium-High | HTTP/2 server drain | connection beginDrain 的后台等待没有自身 deadline | 静态确认 |
| `WS-H2-SETTINGS-002` | **Medium** | High | HTTP/2 protocol | SETTINGS 状态不区分角色，client 可接受 server 的 ENABLE_PUSH=1 | 静态确认 |
| `WS-H2-WRITER-001` | **Medium** | Medium-High | HTTP/2 writer lifecycle | standalone writer abort 与 flow permits 的跨组件清理不原子 | 静态确认 |
| `WS-IPV6-001` | **Medium** | High | HTTP URL execution | URL 支持 IPv6 literal，但 client factory 强制转换为 `HostName` | 静态确认 |
| `WS-POOL-001` | **Medium** | High | Connection pool race | factory 返回后发布连接前未重新检查 cancellation/deadline | 静态确认 |
| `WS-PR41-001` | **Medium** | High | Open PR / Windows PoC | PR #41 的 PE dependency inspection 在 `objdump` 失败时 fail-open | PR patch 静态确认 |
| `WS-RES-002` | **Medium** | High | Resolver efficiency | 每个 resolver job 以 1ms 周期轮询 native 状态 | 静态确认 |
| `WS-RES-003` | **Medium** | High | Resolver FFI validation | Cangjie 侧未 fail-closed 校验 native address family 枚举 | 静态确认 |
| `WS-TIME-001` | **Medium** | Medium-High | Deadline model | 不同注入时钟创建的 Deadline 可被直接比较 | 静态确认 |
| `WS-TLS-CLOSE-001` | **Medium** | Medium | TLS lifecycle | graceful close 与活动 read/write 的并发语义未闭合 | 静态确认；需竞态复现 |
| `WS-TLS-KEY-001` | **Medium** | Medium-High | Key loading | PKCS#8 文件检查与读取分离，存在 TOCTOU | 静态确认 |
| `WS-TLS-LIFE-001` | **Medium** | High | Native resource ownership | 公共 TLS builder eager-create provider，context 无确定性 close | 静态确认 |
| `WS-TLS-OWN-001` | **Medium** | Medium-High | TLS key ownership | built TLS context 仍依赖 caller-owned `PrivateKeyRef` 生命周期 | 静态确认 |
| `WS-TLS-PROFILE-001` | **Medium** | High | TLS policy API | `Compatible` 与 `Modern` 当前安全语义完全相同 | 静态确认 |
| `WS-TLS-SESSION-001` | **Medium** | Medium-High | TLS session store | session lifetime 算术与 policy partition 不够完整 | 静态确认 |
| `WS-CONN-002` | **Low** | Medium | Connector arithmetic | attempt delay 与 candidate ordinal 缺少合理乘法上限 | 静态确认 |
| `WS-HTTP1-PERF-001` | **Low** | High | HTTP/1 allocation | chunked response read 热路径反复分配固定 staging buffer | 静态确认 |
| `WS-RES-004` | **Low** | Medium | Resolver input | optional service 字符串缺少显式 embedded-NUL 校验 | 静态确认 |
| `WS-STDNET-002` | **Low** | High | Resource cleanup | 无效 staging size 可在 socket 构造后、try/finally 前抛出 | 静态确认 |
| `WS-STDNET-003` | **Low** | Medium-High | Resource cleanup | accepted socket 转换失败时缺少显式 close guard | 静态确认 |
| `WS-TLS-SOURCE-001` | **Low** | High | Supply-chain naming | `content_sha256` 实为 commit/tree 标识摘要，不是源码内容归档摘要 | 静态确认 |
| `WS-H1-CONNECT-001` | **Advisory** | High | API completeness | server-side successful CONNECT 尚无公共 tunnel ownership handoff | 静态确认 |

## 5. 详细发现登记

### Critical

#### WS-BUILD-001 — 固定提交缺少标准构建必需的 AWS-LC provider manifest

**类别：** Build / reproducibility  
**置信度：** High  
**验证状态：** 静态确认；未独立执行  

**证据。** `native/tls/aws_lc/` 在固定 Git tree 中只有 `wirestack_tls_provider.c/.h`；`tools/build_linux_tls_provider.py` 无条件读取 `native/tls/aws_lc/provider.json`；`build.cj` 在 pre-build/pre-check/pre-test 等阶段调用该脚本。

**影响。** 干净检出无法仅凭版本库内容完成标准 CJPM 生命周期；已提交的发布与供应链证据依赖版本库之外的隐含输入，破坏可复现性和外部验证。

**修复建议。** 提交 canonical、schema-validated、版本控制的 `provider.json`，或把全部 pin 常量移入一个受版本控制的构建清单；禁止工作区未跟踪文件参与资格化。

**验收标准。** 全新 checkout、空缓存、`git status --porcelain` 为空时执行 `cjpm check && cjpm build && cjpm test` 成功；生成证据后除声明的构建目录外工作区仍干净。

#### WS-CI-001 — 通用 PR 门禁不执行完整 Cangjie clean build/test

**类别：** CI / merge gate  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** Architecture Guard 与 Gate Harness 工作流主要运行 Python 单测、静态规则和 manifest 校验；完整 `cjpm check/build/test` 只出现在 `scripts/check`，未成为所有 PR 的 required check。

**影响。** 源代码、FFI 配置和构建输入损坏仍可在“绿色 Actions”下进入 `main`；WS-BUILD-001 正是该覆盖空洞的现实表现。

**修复建议。** 增加唯一 canonical `Clean Cangjie Build` workflow，在无缓存或受控缓存的干净检出中执行 architecture guard、provider/resolver 构建、CJPM check/build/test、安装后 consumer smoke 和 evidence freshness。

**验收标准。** 任意删除 provider pin、破坏 FFI 路径、引入编译错误或使测试失败，PR required check 均可靠失败；该 check 被分支保护强制。

### High

#### WS-EVID-001 — 发布证据 freshness 未完整绑定 native/build 输入

**类别：** Evidence integrity  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** M7-021 的生产 source tree 主要覆盖 `.cj`、CJPM 文件，qualification input 列表未统一覆盖 provider C/H、provider pin、native build scripts、全部 flags/tool identities；M7-025 又依赖缺失的 provider pin。

**影响。** 原生 provider 或构建逻辑变化后，旧 PASS 证据仍可能被视为 current；证据与当前源码/制品可能漂移。

**修复建议。** 建立单一 `qualification-input-manifest`，覆盖源码、native C/H、pin、构建脚本、工具链、flags、target 和依赖摘要；所有 M7 gate 共用。

**验收标准。** 修改任一受控输入都会使旧证据确定性 stale；重新资格化后所有报告引用相同 input digest。

#### WS-GOV-001 — `main` 未保护且没有 required status checks / ruleset

**类别：** Repository governance  
**置信度：** High  
**验证状态：** GitHub 状态确认  

**证据。** GitHub branch API 报告 `protected=false`、required checks enforcement off；仓库 rulesets 为空。

**影响。** 可以绕过代码审查、构建、协议、安全和证据门直接修改安全网络栈主分支。

**修复建议。** 保护 `main`，禁止直接 push，至少一名独立 review，要求 clean build、测试、架构、API、evidence freshness 和供应链检查；关键目录配置 CODEOWNERS。

**验收标准。** 普通与管理员路径均不能在 required checks/review 缺失时合并；break-glass 有审计记录。

#### WS-H2-SERVER-FLOW-001 — server response 在 writer 入队成功前消耗 DATA send window

**类别：** HTTP/2 flow control  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** server `sendResponse` 先调用 `event.beginData()`，使 permit 从 Reserved 进入 Sending 并扣减 connection/stream window，然后调用普通 `writer.enqueue(frame)`；入队失败时 permit 已无法 cancel。

**影响。** 队列满/关闭时没有 bytes 发出但 connection window 已永久减少；stream reset 不能恢复已消耗的 connection credit，可能逐步卡死 sibling streams。

**修复建议。** 与 client 一样使用 `writer.enqueueReservedData(frame, permit)`，由 writer 在成功接管队列时原子 claim permit；失败路径必须 cancel reserved permit。

**验收标准。** 强制 writer enqueue 失败后 sendConnectionWindow、stream window、reserved bytes 和 permit count 全部恢复原值；siblings 继续发送。

#### WS-H2-SETTINGS-001 — 把本地资源上限当作 peer RFC 默认值，且未完整广告非默认 SETTINGS

**类别：** HTTP/2 protocol  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** `Http2SettingsState` 以 `defaultHttp2Settings(limits)` 同时初始化 peer/local state；client 初始帧主要发送 ENABLE_PUSH=0，server 发送 ENABLE_PUSH/MAX_CONCURRENT_STREAMS，其他非默认 limits 未必发送。

**影响。** 本端 flow window、HPACK table、max frame/header list 等认知可与 peer 按 RFC 默认值的认知不同，导致合法流量被拒绝、错误 window accounting 或互操作失败。

**修复建议。** 分离 RFC peer defaults、local hard caps、advertised local state、acknowledged local state；启动时对所有偏离 RFC 默认的接收参数显式发送 SETTINGS。

**验收标准。** 对每个非默认 local limit，首个 SETTINGS 包含正确值；peer state 初始严格使用 RFC 默认；互操作测试覆盖默认与非默认组合。

#### WS-H2-WRAP-001 — 公共 cancellation wrapper 破坏 HTTP/2 END_STREAM/trailer 完成语义

**类别：** HTTP/2 body completion  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** 底层 H2 response body 使用 `completeAtDeclaredLength=false`，要求等待协议终止；`HttpRequestCancellationOperation.wrap` 和 server request wrapper 新建 `ResponseBody` 时使用默认 `true`。

**影响。** 读满 Content-Length 后外层会过早标记 fully-consumed 并释放 cancellation links，即使 END_STREAM/trailers 尚未到达；可能丢失 trailer、错误复用完成状态或使后续取消无法唤醒等待。

**修复建议。** wrapper 必须保留 delegate 的 completion policy，或以透明 observer/decorator 实现，不重建语义不同的 `ResponseBody`。

**验收标准。** H2 响应含 Content-Length 且 trailer 延迟到达时，读满 payload 后仍未 completed；收到 END_STREAM/trailer 后才释放注册并可复用。

#### WS-LIC-001 — 项目自身缺少明确 LICENSE 和正式发行许可入口

**类别：** Legal / release  
**置信度：** High  
**验证状态：** 仓库元数据与根目录确认  

**证据。** 仓库 metadata 的 `license` 为 null，根目录未见 LICENSE；GitHub Releases 为空。

**影响。** 外部用户无法确定使用、修改和再分发 Wirestack 源码与制品的权利；第三方 notices 与项目许可无法形成完整发布包。

**修复建议。** 增加项目 LICENSE、THIRD_PARTY_NOTICES、provider/license inventory，并把许可文件打入源码与二进制发行包。

**验收标准。** GitHub 正确识别许可证；安装包含项目许可及全部必要第三方 notice；SBOM 的 licenseDeclared 与发布内容一致。

#### WS-PROXY-001 — HTTPS CONNECT 池键未包含代理认证身份

**类别：** Proxy identity / pooling  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** `Http1HttpsProxyClient.execute` 的 pool key 含 proxy endpoint identity、origin、TLS/trust/client identity/provider/ALPN，但不含本次 `proxyAuthorization` 或稳定 credential identity；factory 才把凭据写入 CONNECT。

**影响。** 同一客户端对相同代理/origin 使用不同凭据时，后续请求可能复用由另一凭据建立的隧道，混淆租户、审计和授权边界。

**修复建议。** authorization provider 必须返回 stable credential partition identity；将其纳入 pool key。无法提供时，动态认证 CONNECT 禁止复用。

**验收标准。** 两组代理凭据对同一 origin 永不共享隧道；相同 credential identity 才允许复用。

#### WS-RES-001 — 活动 `getaddrinfo` 无法取消，resolver close 的完成时间依赖外部 NSS/DNS 返回

**类别：** Resolver availability  
**置信度：** Medium-High  
**验证状态：** 静态确认；系统行为依赖平台  

**证据。** native resolver 使用固定 pthread pool 执行阻塞 `getaddrinfo`；job cancellation 可让调用方返回，但不能中断已进入 libc 的调用；pool destroy/close 需要等待 worker 退出。

**影响。** 恶意或故障 NSS/DNS backend 可导致进程 shutdown、测试 teardown 或资源回收长期阻塞。

**修复建议。** 将 blocking resolver 置于可终止 helper process，或采用平台异步 resolver；至少给 close 定义有界超时、detached quarantine 和明确 residual risk。

**验收标准。** 注入永不返回的 resolver backend 时，公共 close/shutdown 在规定上限内完成且无 UAF。

#### WS-RETRY-001 — 写超时可能在未知物理提交状态下被标为可重试

**类别：** HTTP retry / commit evidence  
**置信度：** Medium-High  
**验证状态：** 静态路径确认；需故障注入复现  

**证据。** `StdNetTransport.writeSome` 在 `socket.write` 抛 `SocketTimeoutException` 时返回 `Retryability.Temporary`；HTTP/1 write tracker 仅在 `writeSome` 正常返回后累计 wire/body bytes；retry policy 对 Temporary + replayable/idempotent 请求允许重试。

**影响。** 底层写可能已向 peer 提交部分请求，但上层 evidence 仍为零；自动重试可能重复执行操作。

**修复建议。** 写错误必须携带 commit certainty/possibleBytesWritten；无法证明零提交的写超时默认 `Unknown/Never`，仅 `SafeBeforeWrite` 才允许无条件重试。

**验收标准。** 故障注入模拟“部分写后超时”，默认策略不得重试；零字节确定失败仍可按策略重试。

#### WS-STDNET-001 — 取消单次 `accept` 会永久关闭整个 listener

**类别：** Transport lifecycle  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** `StdNetTransportListener.accept` 将 cancellation callback 注册为 `gate.interrupt { close() }`；`close()` 永久关闭底层 `TcpServerSocket`。

**影响。** 一个请求作用域 deadline/cancel 可终止整个服务监听器，后续所有 accept 失败；接口未清楚表达该 terminal 语义。

**修复建议。** 由单 owner accept loop 持有底层 listener，将 accepted transports 放入有界 channel；调用方取消只取消 channel wait。若 SDK 限制无法避免，应把 terminal 行为冻结为显式 API。

**验收标准。** 取消一个等待中的 accept 后，下一次 accept 仍能成功；显式 listener close 才终止服务。

#### WS-TLS-TRUST-001 — 系统信任变化不会可靠改变 TLS session partition

**类别：** TLS trust / session resumption  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** Linux bundle `sourceIdentity` 仅含路径和文件大小；hashed directory 仅含路径。TLS session key 使用该 identity。相同大小替换 bundle 或目录内容变化不会改变 key。

**影响。** 删除/替换受信根后，旧 session ticket 仍可能在旧 trust partition 下被 offer/resume，绕过调用方对“信任集合已更新”的预期。

**修复建议。** 对选中的 bundle/hashed directory 计算稳定内容摘要或可信版本 token；检测变化时清空相关 session；无法可靠 version 时禁用跨进程/长期 resumption。

**验收标准。** 同路径同大小替换 CA 内容、增加/删除 hashed cert 后 session key 改变，旧 ticket 不再被 offer。

### Medium

#### WS-API-001 — `ByteSpan` 宣称 immutable，却公开可变 `Array<Byte>` backing

**类别：** Transport API  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** `ByteSpan` 的 `bytes` 是 public `Array<Byte>`；`let` 只固定引用，不阻止元素修改。

**影响。** 调用方可在写入过程中修改 backing array，形成 TOCTOU、并发数据竞争和“同一 span 内容稳定”契约破坏。

**修复建议。** 使用真正只读 byte storage/view，或明确改名为 borrowed mutable-stable view并要求调用期间不可修改；异步持有时复制/lease。

**验收标准。** 类型系统或运行时保证 source 在操作生命周期内不可被修改；并发修改测试被禁止或确定性隔离。

#### WS-API-ALIAS-001 — 公共 package 通过 type alias 绑定 internal 类型身份

**类别：** Public API / ABI  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** `wirestack.http`、`wirestack.tls` 大量 public alias 指向 `wirestack.internal.*`；API baseline 固化这些 resolved targets。

**影响。** internal 包移动、拆分、布局变化成为公共破坏性变更；“internal 可自由重构”不成立。

**修复建议。** 由公共 contract package 定义类型，internal 实现依赖 contract；或承认并重命名这些包为稳定 ABI。

**验收标准。** 重构 internal 文件/package 不改变公共 symbol identity 和 consumer baseline。

#### WS-CANCEL-001 — 公共 cancellation callback registry 无硬上限

**类别：** Cancellation resources  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** `CancellationState.callbacks` 是无容量限制的 HashMap；相邻 `OperationCompletion` 已采用 maxCleanups。

**影响。** 错误循环注册或恶意使用一个 token 可持续增长内存。

**修复建议。** 增加 maxRegistrations、metrics 和 overflow error；或把通用 register 限制为 internal，公共层只提供受控 handle。

**验收标准。** 超过上限确定性失败，所有已注册 callback 仍 exactly-once，close/cancel 后计数归零。

#### WS-CI-SUPPLY-001 — 安全/发布工作流依赖 mutable action tags 和滚动环境

**类别：** CI supply chain  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** actions/checkout@v4、setup-python@v5、upload-artifact@v4、msys2 action major tag及 update=true 等未固定完整 digest/包快照。

**影响。** 同一提交的资格化环境可随上游 action/包变化，且 workflow dependency compromise 影响证据链。

**修复建议。** 发布与安全 gate 固定 action commit SHA、container image digest、包版本/镜像；生成 runner environment manifest。

**验收标准。** 同一 commit 的 workflow dependency graph 有固定 digest，升级必须显式 PR。

#### WS-CONN-001 — Happy Eyeballs 为全部 candidate 立即 spawn task

**类别：** Connector resources  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** 候选数可达较大上限，connector 为每个 candidate 建立 future，再由内部 delay 控制启动。

**影响。** 恶意/异常 resolver 结果可瞬时制造大量 task、timer 和 closure，即使实际并发连接受时间间隔控制。

**修复建议。** 滚动 admission：仅保持固定数量待启动/活动 attempt；达到 winner 后不再创建剩余 tasks。

**验收标准。** 1024 candidates 时 task 峰值受显式小上限约束，所有 loser joined/cleaned。

#### WS-H2-BODY-001 — 未知 Content-Length 响应的 `bodyBytes` 统计始终为零

**类别：** HTTP/2 diagnostics  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** `Http2ClientResponseSequence.acceptData` 仅在 expectedContentLength 存在时增加 receivedBodyBytes。

**影响。** 流式/未知长度响应的指标、审计和 benchmark 失真；未来若复用该计数做限制会引入逻辑错误。

**修复建议。** 无条件 checked-add received bytes，Content-Length 只控制一致性校验。

**验收标准。** 未知长度多 DATA 响应的 bodyBytes 等于总 payload。

#### WS-H2-BUFFER-001 — 入站 body queue 复用 outbound `maxPendingWrites` 且无独立 byte cap

**类别：** HTTP/2 buffering  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** client/server body channel 以 `limits.maxPendingWrites` 作为 maxSegments；没有独立 maxBufferedBodyBytes。

**影响。** 调整写队列会意外改变接收背压；大 frame × segment count 决定内存但缺少直接配置/指标。

**修复建议。** 新增 maxBufferedBodySegments 和 maxBufferedBodyBytes，分别计数并暴露 metrics。

**验收标准。** 任一维度达到上限都以 stream-level bounded terminal 结束，credit/registrations 全回收。

#### WS-H2-DRAIN-001 — connection beginDrain 的后台等待没有自身 deadline

**类别：** HTTP/2 server drain  
**置信度：** Medium-High  
**验证状态：** 静态确认  

**证据。** beginDrain spawn task 等 registry empty，再 close writer；单个永不结束的 stream 可无限保留该 task/connection，除非外层另行 force abort。

**影响。** 单独使用 `Http2ServerConnection.close()` 时 shutdown 可无限挂起。

**修复建议。** beginDrain 接收 Deadline/OperationContext，超时后 RST remaining streams + abort；返回可 await 的 drain handle/result。

**验收标准。** 故意不结束的 stream 下，drain 在配置上限后强制收敛且无 task leak。

#### WS-H2-SETTINGS-002 — SETTINGS 状态不区分角色，client 可接受 server 的 ENABLE_PUSH=1

**类别：** HTTP/2 protocol  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** 通用 apply settings 对 ENABLE_PUSH 只转 Bool；没有 client/server role validation。

**影响。** 违反 HTTP/2 角色规则，降低对错误/恶意 server 的 fail-closed 性。

**修复建议。** settings state 持有 role；client 收到 server ENABLE_PUSH=1 返回 connection PROTOCOL_ERROR。

**验收标准。** 角色矩阵测试覆盖 client/server 收到 0、1、非法值。

#### WS-H2-WRITER-001 — standalone writer abort 与 flow permits 的跨组件清理不原子

**类别：** HTTP/2 writer lifecycle  
**置信度：** Medium-High  
**验证状态：** 静态确认  

**证据。** writer.abort 失败 queued tickets，但 queued reserved DATA permit 的释放依赖外层 closer 随后 flow.close；preserving-ticket cancel 对 DATA queue 的假设也不显式。

**影响。** 非 canonical 调用或未来重构可留下 reserved permit/窗口状态不一致。

**修复建议。** writer queue item 自身拥有 permit cleanup；abort/cancel 在同一路径完成 ticket + permit terminal。

**验收标准。** 直接 writer.abort 后 permit/reserved bytes 为零，不依赖额外 flow.close。

#### WS-IPV6-001 — URL 支持 IPv6 literal，但 client factory 强制转换为 `HostName`

**类别：** HTTP URL execution  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** HttpUrl 可解析 bracketed IPv6；cleartext/TLS/proxy handshaker 路径对 origin host 调用 `HostName(...)`，含冒号 literal 不满足 DNS HostName。

**影响。** `http://[::1]` / `https://[::1]` 等合法 URL 无法端到端执行，且 TLS IP reference identity 路径无法由默认 HTTP client 到达。

**修复建议。** HttpUrl 保留 typed host variant `DnsName | IpAddress`；resolver/connector/TLS 分别走 typed 分支。

**验收标准。** IPv4/IPv6 literal 的 HTTP、HTTPS、Host/:authority/SNI/reference identity 全部端到端测试通过。

#### WS-POOL-001 — factory 返回后发布连接前未重新检查 cancellation/deadline

**类别：** Connection pool race  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** pool 预留容量后调用 factory，成功后直接登记/返回 lease；现有取消测试覆盖等待者，不覆盖 factory 完成边界。

**影响。** 取消可在连接刚建立后获胜，但调用方仍收到或池中保留新连接，违背 operation terminal selection。

**修复建议。** factory 成功后、publish 前重新 check context；若已 terminal，立即 discard 并回滚 reservation。

**验收标准。** 确定性 barrier 让 cancel 与 factory completion 交叉，取消 winner 时无 lease 发布、连接已关闭、计数归零。

#### WS-PR41-001 — PR #41 的 PE dependency inspection 在 `objdump` 失败时 fail-open

**类别：** Open PR / Windows PoC  
**置信度：** High  
**验证状态：** PR patch 静态确认  

**证据。** `base.run(["objdump", "-p", binary], check=False)` 后直接解析 stdout，未验证 returncode；空/错误输出可能产生空 forbidden dependency 列表。

**影响。** Windows provider PoC 可能在依赖扫描工具不可用/失败时错误 PASS。

**修复建议。** objdump 非零立即失败；验证输出至少包含合法 PE headers/import section；action/toolchain 固定版本并重跑矩阵。

**验收标准。** 删除 objdump、传损坏 PE、让工具返回非零时 gate 均 FAIL。

#### WS-RES-002 — 每个 resolver job 以 1ms 周期轮询 native 状态

**类别：** Resolver efficiency  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** Cangjie bounded backend 在 pending 时 sleep 1ms 再 poll。

**影响。** 大量并发 DNS 产生 scheduler wakeup/CPU 放大，移动端尤为明显。

**修复建议。** 使用 condition/eventfd/pipe 或 native completion queue；至少指数退避且保持 deadline 精度。

**验收标准。** 并发慢 DNS 时 wakeup 数与 job 完成数近似线性，而非 duration/1ms。

#### WS-RES-003 — Cangjie 侧未 fail-closed 校验 native address family 枚举

**类别：** Resolver FFI validation  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** 结果转换把非 IPv4 值落入 IPv6 分支，而不是只接受明确 IPv6 常量。

**影响。** native 内存损坏、ABI 漂移或实现 bug 会被错误解释为 IPv6 数据，弱化 FFI 边界。

**修复建议。** 显式 match 允许值；未知 family 返回 provider/system failure并释放 job。

**验收标准。** 注入未知 family 时无地址发布且返回稳定 typed error。

#### WS-TIME-001 — 不同注入时钟创建的 Deadline 可被直接比较

**类别：** Deadline model  
**置信度：** Medium-High  
**验证状态：** 静态确认  

**证据。** Deadline 内部保存 clock，但 `OperationContext.withEarlierDeadline` 只比较 `expiresAt`，不验证 clock domain。

**影响。** 独立 virtual clocks 的 absolute value 不具可比性，可能选择错误预算或让 child context 使用另一时钟域。

**修复建议。** Deadline 带不可伪造 clock-domain identity；组合时要求相同 domain，或只允许相对 shorten。

**验收标准。** 不同 clock domain 的合并明确抛错；同 domain 的 earlier-deadline 行为保持。

#### WS-TLS-CLOSE-001 — graceful close 与活动 read/write 的并发语义未闭合

**类别：** TLS lifecycle  
**置信度：** Medium  
**验证状态：** 静态确认；需竞态复现  

**证据。** `TlsConnection.close` 将 lifecycle 设为 Closing 后直接驱动 shutdown，没有等待或中断已标记 active 的 read/write；abort 路径才明确唤醒底层。

**影响。** 并发 close 可能退化为异常、非 graceful close，或受底层锁/阻塞行为影响；调用者无法预测。

**修复建议。** 冻结契约：close 等待活动操作、取消它们，或立即返回 ConcurrentOperation；所有路径有共同 deadline。

**验收标准。** blocked read/write 与 close 的每种 winner order 都在有界时间内终止并产生唯一 closure evidence。

#### WS-TLS-KEY-001 — PKCS#8 文件检查与读取分离，存在 TOCTOU

**类别：** Key loading  
**置信度：** Medium-High  
**验证状态：** 静态确认  

**证据。** 文件 metadata/regular/readable/size 检查与随后 open/read 不是同一 no-follow handle。

**影响。** 本地攻击者可在检查后替换 symlink/file，使库读取不同对象或非预期权限内容。

**修复建议。** 一次打开 no-follow handle，基于该 handle fstat、限制权限/owner，再读取固定长度。

**验收标准。** 并发替换与 symlink 测试不能改变被验证对象；异常路径清零 buffer。

#### WS-TLS-LIFE-001 — 公共 TLS builder eager-create provider，context 无确定性 close

**类别：** Native resource ownership  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** public TLS builder 构造即创建 `AwsLcTlsProvider`；context 持有 provider，但未实现 Resource/close；最终依赖 provider finalizer。

**影响。** 大量放弃 builder/context 时 native provider、ticket key、session store 的回收时机不可预测。

**修复建议。** builder 纯配置；build 时获取共享/refcount provider lease，context 实现确定性资源模型或使用进程级 runtime owner。

**验收标准。** 批量创建/丢弃 builder 不增加 native live provider；context 关闭后最后一个 lease 才销毁 provider。

#### WS-TLS-OWN-001 — built TLS context 仍依赖 caller-owned `PrivateKeyRef` 生命周期

**类别：** TLS key ownership  
**置信度：** Medium-High  
**验证状态：** 静态确认  

**证据。** `LocalIdentity` 保留 PrivateKeyRef；context 构建不取得独立 lease/import；调用方可在后续 engine creation 前 close key。

**影响。** 声明为 immutable/shareable 的 context 可能因外部对象关闭而在使用时失败。

**修复建议。** context build 取得 refcounted lease/opaque imported key；或把 context 明确设为借用并在类型/API 中表达 owner。

**验收标准。** 构建 context 后原始 wrapper close 不影响 context，或编译/API 禁止该用法。

#### WS-TLS-PROFILE-001 — `Compatible` 与 `Modern` 当前安全语义完全相同

**类别：** TLS policy API  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** `TlsSecurityPolicy.forProfile` 对除 StrictTls13 外的 profile 都返回 TLS1.2–1.3，并共享相同布尔策略；无独立 cipher/group/signature policy。

**影响。** 公共名称暗示差异但实际没有，未来改变其中之一还会影响 session partition/兼容承诺。

**修复建议。** 合并无差异 profile，或定义并测试 provider-neutral 差异；manifest/runtime info 应能描述实际 policy。

**验收标准。** 每个保留 profile 有机器可验证的独特规则和互操作/negative tests。

#### WS-TLS-SESSION-001 — session lifetime 算术与 policy partition 不够完整

**类别：** TLS session store  
**置信度：** Medium-High  
**验证状态：** 静态确认  

**证据。** expiry 使用 `Int64(lifetimeSeconds) * Duration.second`，未显式限制转换/乘法；securityContext key 只有 min/max TLS version，不含 profile。

**影响。** 异常 provider lifetime 可溢出；未来 Modern/Compatible 分化后仍可能共享 session partition。

**修复建议。** clamp 到明确最大 ticket lifetime并 checked arithmetic；key 加入稳定 policy digest。

**验收标准。** UINT64_MAX lifetime 不溢出；任意 policy 差异必改变 key。

### Low

#### WS-CONN-002 — attempt delay 与 candidate ordinal 缺少合理乘法上限

**类别：** Connector arithmetic  
**置信度：** Medium  
**验证状态：** 静态确认  

**证据。** 启动延迟由 ordinal × attemptDelay 推导，构造只验证非负/候选上限，未冻结总 schedule ceiling。

**影响。** 极端配置可产生溢出或不可用的超长连接计划。

**修复建议。** checked multiply并限制 total stagger <= operation deadline/合理 ceiling。

**验收标准。** 极端 delay/candidate 组合明确拒绝，不溢出。

#### WS-HTTP1-PERF-001 — chunked response read 热路径反复分配固定 staging buffer

**类别：** HTTP/1 allocation  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** chunked response stream 每次 read cycle 创建新的约 16 KiB array。

**影响。** 高频小块/SSE 场景增加 GC 压力；不是正确性缺陷。

**修复建议。** connection/body owner 复用有界 staging buffer并保留单 reader约束。

**验收标准。** allocation benchmark 显示 steady-state read 不再每次分配。

#### WS-RES-004 — optional service 字符串缺少显式 embedded-NUL 校验

**类别：** Resolver input  
**置信度：** Medium  
**验证状态：** 静态确认  

**证据。** HostName 有严格校验，但 service 到 CString 的路径未见同等 NUL 约束。

**影响。** 包含 NUL 的 service 可能被 native 截断，造成调用者与 resolver 解释不一致。

**修复建议。** 服务名采用 typed port/service token并拒绝 NUL/超长。

**验收标准。** NUL service 在 FFI 前失败。

#### WS-STDNET-002 — 无效 staging size 可在 socket 构造后、try/finally 前抛出

**类别：** Resource cleanup  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** `StdNetTransport.connect` 先创建 TcpSocket，再在 adapter init 校验 staging size，外层 try 从 connectSocket 才开始。

**影响。** 错误输入路径依赖 runtime/finalizer 回收未连接 socket。

**修复建议。** 在 socket 构造前校验所有参数，或立即进入 owner guard。

**验收标准。** 无效参数时不创建 native socket。

#### WS-STDNET-003 — accepted socket 转换失败时缺少显式 close guard

**类别：** Resource cleanup  
**置信度：** Medium-High  
**验证状态：** 静态确认  

**证据。** server.accept 成功后调用 `StdNetTransport.fromAccepted`；endpoint conversion/constructor 抛错时没有局部 finally 关闭 accepted socket。

**影响。** 罕见 address conversion/unsupported address 路径依赖 GC 回收。

**修复建议。** accepted socket 立即放入 guard，ownership transfer 成功后 disarm。

**验收标准。** 注入 fromAccepted 失败时 fd/socket count 不增加。

#### WS-TLS-SOURCE-001 — `content_sha256` 实为 commit/tree 标识摘要，不是源码内容归档摘要

**类别：** Supply-chain naming  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** build script 计算 SHA256(commit + newline + tree + newline)。

**影响。** 字段名可能误导审计者，以为完成独立源字节校验。

**修复建议。** 改名 `git_object_fingerprint_sha256`，并额外生成 canonical source archive digest。

**验收标准。** manifest 同时记录 commit、tree、canonical archive SHA-256，命名无歧义。

### Advisory

#### WS-H1-CONNECT-001 — server-side successful CONNECT 尚无公共 tunnel ownership handoff

**类别：** API completeness  
**置信度：** High  
**验证状态：** 静态确认  

**证据。** 内部 framing 能识别 Tunnel，但上层 server 生命周期最终关闭 transport，未向 handler 返回 owned duplex tunnel。

**影响。** 实现语义与“server CONNECT/tunnel 支持”宣传需区分；不是现有普通 HTTP 路径漏洞。

**修复建议。** 要么明确列为 non-goal，要么新增显式 hijack/tunnel API、ownership 与 deadline/cancellation 契约。

**验收标准。** 文档与 capability manifest 不再暗示未提供的 tunnel handoff，或完整端到端测试通过。

## 6. 协议符合性矩阵

| 领域 | 结论 | 说明 |
|---|---|---|
| HTTP/1.1 exact CRLF / obs-fold | PASS | parser 对 bare LF、CR 后非 LF、首空白行均 fail-closed |
| HTTP/1.1 CL/TE / duplicate CL | PASS | 共享 framing 决策拒绝歧义与冲突 |
| HTTP/1.1 Host / absolute-form / CONNECT authority | PASS | Host 必须唯一且与 target 一致 |
| HTTP/1.1 chunked / trailer | PASS | 逐状态解析、累计/行/字段上限、EOF 不完整报错 |
| HTTP/2 frame shape / reserved bit | PASS | 长度、stream 0/非0、固定 payload shape 有校验 |
| HTTP/2 header-block contiguity | PASS | HEADERS/CONTINUATION interleaving 由状态机约束 |
| HTTP/2 stream parity / monotonic id / exhaustion | PASS | registry/state machine 有角色与范围约束 |
| HTTP/2 HPACK/Huffman bounds | PASS | 整数、encoded/decoded bytes、dynamic table、field/list 均有界 |
| HTTP/2 SETTINGS defaults/advertisement | FAIL | local limits 与 RFC defaults 混用，非默认值未完整广告 |
| HTTP/2 ENABLE_PUSH role rule | FAIL | client 收到 server ENABLE_PUSH=1 未显式 connection error |
| HTTP/2 send flow-control atomicity | PARTIAL | client reserved enqueue 正确；server 先扣 window 再普通 enqueue |
| TLS chain + reference identity | PASS with caveat | provider 验证 chain/SAN；session trust-source versioning 不完整 |
| TLS SNI / identity separation | PASS | API 与 engine 分开设置 |
| TLS pinning / custom/system roots | PASS with caveat | 无 TrustAll；系统 trust 更新不会可靠分区 session |
| TLS external signer callback | PASS | 用户 signer 在 engine mutex 外调用，失败 fail-closed |
| TLS close_notify / truncation | PASS with caveat | typed evidence 存在；并发 graceful close 契约未闭合 |

### 6.1 HTTP/1.1

静态审计未发现典型 CL/TE request smuggling、重复 Host 混淆、obs-fold 宽松接受、bare-LF 容错或 chunk terminator 宽松解析入口。parser 与 serializer 共用 framing 决策，是正确设计。仍需通过持续 corpus 维护和 differential tests 对抗未来回归。

### 6.2 HTTP/2

frame、header block、stream lifecycle、HPACK 与资源上限总体强；主要问题集中在 SETTINGS 状态来源与跨组件 flow permit ownership。它们不是 parser 小瑕疵，而是会在非默认配置、队列故障或跨层包装时破坏协议状态一致性的系统性问题。

### 6.3 TLS

provider-neutral memory-BIO engine、SNI/reference identity 分离、SAN/IP 验证、外部 signer 锁外调用、敏感数据清理均正确。最需要修复的是 system trust 版本与 session resumption 的绑定，以及 public context/provider/key 的确定性 ownership。

## 7. 锁、任务与资源所有权矩阵

| 对象 | Owner | 同步机制 | 终止路径 | 审计结论 |
|---|---|---|---|---|
| CancellationState | CancellationSource | Mutex + AtomicBool | cancel 一次，锁外运行 callbacks | callback registry 无上限 |
| OperationCompletion | 单 operation | Mutex | winner claim 全部 cleanup，锁外执行 | 设计良好 |
| StdNetTransport | transport instance | lifecycleMutex + read/write flags | close/abort 关闭 socket | accept cancel 升级为 listener close |
| Native ResolverPool/Job | SystemResolver/provider | pthread mutex/cond + job state | job release / pool destroy join workers | 活动 getaddrinfo 不可中断 |
| AwsLcTlsProvider | public/internal context owner | provider Mutex + C handle | close/finalizer | public context 无确定性 close |
| AwsLcTlsEngine | TlsConnection | engine Mutex + C handle | engine close once | 配置/IO 序列化良好 |
| TlsConnection | connection owner | lifecycleMutex + pump/transport | close/abort + releaseEngineOnce | graceful close 与 active IO 未冻结 |
| Http1ConnectionPool | HttpClient pipeline | pool Mutex + reservations/leases | release/discard/close | factory completion 后 cancel race |
| ResponseBody | response owner | stateMutex | completed/abandoned exactly once | H2 wrapper 改变 completion policy |
| Http2ConnectionReader | connection | 唯一 reader task | reader termination registry | 模型正确 |
| Http2WriteScheduler | connection | writer mutex/condition + unique writer task | ticket terminal / transport finish | permit cleanup 跨组件依赖 |
| Http2FlowController | connection | flow mutex/condition | closeStream/close | server claim-before-enqueue 缺陷 |
| Http2StreamRegistry/Exchange | connection/stream | registry/exchange locks | END/RST/GOAWAY/cancel | 整体模型强，需补边界测试 |

## 8. 测试、fuzz、性能与 soak 评价

### 8.1 优点

- unit/integration/race 测试数量大，Transport、TLS、HTTP/1、HTTP/2 都不是只测 happy path；
- M7-023 保留固定 corpus、确定性 mutation 和 replay coordinates，当前报告汇总 6,465 次确定性迭代；
- M7-024 汇总 raw TCP、cancellation、DNS→connected、TLS、HTTP/1、HTTP/2、SSE 七个域；多个性能门使用同 binary、11 measured rounds + 1 warmup；
- M7-021 采用“打包→解压→作为 clean CJPM consumer dependency→运行 HTTPS/runtime smoke→扫描依赖”的形状，这是正确资格化模型；
- M7-022 没有把 10 秒 preflight 冒充 24h PASS，保持 fail-closed。

### 8.2 限制

- M7-023 是固定语料 + 确定性变异，不等价于 coverage-guided continuous fuzz；
- 性能与发布证据由仓库自报，本次未独立复算；
- M7-022 正式 86,400 秒运行尚未完成，且历史上短测绿色后仍出现过公共 HTTP/2 concurrent response-body 缺陷；
- evidence freshness 对 native/build inputs 不完整；
- 通用 GitHub Actions 没有执行完整 CJPM 生命周期。

### 8.3 必须新增的回归测试

1. clean checkout、空缓存、无未跟踪 pin 的完整 build/test；
2. factory completion 与 cancellation 同一 publication boundary；
3. H2 Content-Length 已读满但 END_STREAM/trailer 延迟；
4. 所有非默认 local HTTP/2 limits 必须出现在初始 SETTINGS；
5. client/server ENABLE_PUSH 角色矩阵；
6. server DATA reserved permit 在 writer enqueue 失败时完整回滚；
7. proxy dynamic credential identity 的 tunnel partition；
8. 同路径同大小替换 system CA 后旧 TLS session 不再复用；
9. IPv4/IPv6 literal 的 HTTP/HTTPS 端到端；
10. 取消单次 accept 后 listener 仍可服务，或测试明确冻结 terminal contract；
11. 部分物理写后 timeout 的 retry commit evidence；
12. 永不返回 resolver backend 下的有界 close/shutdown。

## 9. 跨平台与发布矩阵

| 平台 | 当前真实状态 | 发布判断 | 主要缺口 |
|---|---|---|---|
| Linux x86_64 glibc | 主体实现 + 大量 native evidence | NO-GO | 构建输入、CI、High findings、24h soak、独立审查/签名未闭合 |
| Linux musl | ADR 延后 / 非当前发布目标 | BLOCKED/DEFERRED | 等待 SDK 正式支持与独立资格化 |
| Windows x86_64 | PR #41 provider PoC；生产平台包仍非完整实现 | BLOCKED | PoC 不等于 Cangjie Transport/TLS/HTTP 产品路径；PR 扫描 fail-open |
| macOS ARM64 | provider PoC/证据增量；Apple 平台适配未形成发布路径 | BLOCKED | 缺生产 adapter、trust/key/network 与 consumer release |
| Android | 占位平台包 / 缺 native 完成证据 | BLOCKED | 需真机生产路径 |
| iOS | Apple 占位 / 缺 native 完成证据 | BLOCKED | 需真机生产路径 |
| HarmonyOS/OpenHarmony | 占位平台包 / 缺 native 完成证据 | BLOCKED | 需原生环境生产路径 |

Windows PR #41 当前仍为 open、未合并，head 为 `44c5bef...`，base 记录已明显早于当前 `main`。它是 provider-neutral PoC 证据增量，不是 Windows production Wirestack；合并前应 rebase、修复 `objdump` fail-open、固定 action/toolchain，并重新跑完整矩阵。

## 10. 公共 API 稳定性与易用性

### 10.1 主要优点

- body replayability、response single-owner、redirect credential stripping、retry fail-closed 都适合标准库默认语义；
- public HTTP/TLS API 没有直接暴露 `TcpSocket`、`SSL_CTX`、`X509` 等 provider-native object；
- typed cancellation handle 区分 request/connection/stream，比一个模糊 token 更容易表达 HTTP/2 sibling 语义。

### 10.2 1.0 前必须解决

- public alias 对 internal type identity 的绑定；
- ByteSpan 的“immutable”虚假承诺；
- typed host 必须保留 DNS/IP variant，不能 parse 后再退化为 String/HostName；
- TLS context/provider/private-key owner 与 close contract；
- H1 accept cancellation 和 H1 request cancellation 会升级为 connection/listener terminal 的可见性；
- server CONNECT/tunnel 是否真正属于公开能力。

## 11. 推荐修复序列

### PR-A：Release integrity / clean build closure

1. 提交 canonical provider pin；
2. 新增 clean CJPM build/test required workflow；
3. 保护 main + CODEOWNERS；
4. LICENSE / notices；
5. 统一 qualification input manifest；
6. action/toolchain digest pin；
7. 从固定 commit 重新生成 M7-021/M7-025。

### PR-B：HTTP/2 correctness closure

1. 修复 H2 cancellation wrapper completion policy；
2. 重构 SETTINGS defaults/caps/advertisement/role；
3. server 使用 atomic reserved-data enqueue；
4. 独立 inbound body buffer limits；
5. 修复 body metrics与 writer permit ownership；
6. 增加上述 deterministic failure tests。

### PR-C：Security partition closure

1. proxy credential identity 入 pool key；
2. system trust content version 入 session key；
3. policy digest 入 TLS session partition；
4. key file no-follow single-handle load。

### PR-D：Transport lifecycle / retry closure

1. accept cancellation 不关闭 listener；
2. write commit certainty；
3. factory publish boundary recheck；
4. resolver close bounded；
5. cancellation registry bound；
6. Happy Eyeballs rolling admission。

### PR-E：Public API freeze

1. 公共 contracts 拥有类型；
2. typed URL host；
3. read-only/borrowed span contract；
4. provider/key/context lease；
5. capability 与 non-goal 文档同步。

### PR-F：Linux RC qualification

1. 全部 Critical/High 关闭；
2. clean consumer + dependency scan；
3. coverage-guided fuzz / sanitizer；
4. 不间断 24h soak；
5. 独立安全 review；
6. signed artifact + SBOM/provenance；
7. protected release tag / reproducibility verification。

## 12. Linux RC 的硬性验收门

只有以下条件同时满足，才建议发布 Linux RC：

- 固定提交可从干净 checkout 独立 build/test；
- 0 个 Critical、0 个未接受 High；
- HTTP/1、HTTP/2、TLS corpus + differential/interoperability tests 当前；
- native C 与 Cangjie 路径的 sanitizer/泄漏测试通过；
- 正式 86,400 秒 soak 通过；
- artifact 两次构建 byte-identical；
- consumer install smoke 通过；
- 无系统 OpenSSL 动态依赖/loader string；
- SBOM、provider manifest、toolchain、input digest、artifact digest一致；
- 独立 reviewer 签字；
- release artifact/tag 签名可验证；
- main/release branch protection 强制所有门。

## 13. 六平台完成定义

Provider PoC、交叉编译、占位 package 或共享源码可编译都不能算平台支持。每个平台必须独立具备：

1. production Transport adapter；
2. trust store / key store / secure random；
3. TLS provider build 与 runtime integration；
4. HTTP/1 + HTTP/2 client/server integration；
5. cancellation/deadline/close native semantics；
6. 真机或原生 VM evidence；
7. platform artifact packaging + consumer smoke；
8. leak/fuzz/soak/failure injection；
9. signed release provenance。

## 14. 审计限制与置信边界

- 本报告是固定提交的全仓静态审计与证据审计，不是形式化证明；
- 审计环境 DNS 故障阻止独立 clone/build/test，所有动态 PASS 都明确视为仓库自报；
- 未声称不存在未发现缺陷，尤其是 Cangjie runtime/std.net 平台行为、真实网络故障和 native ABI 并发只能通过执行验证；
- Medium/Low 中标注“需故障注入”的项目应以 deterministic test 决定最终严重度；
- 本报告不把历史 PR 或未合并分支代码归入 `main`，PR #41 单独列示。

## 15. 最终判断

Wirestack 的核心方向值得保留：它在协议严格性、资源边界、provider-neutral TLS、typed lifecycle 和证据工程上明显强于普通早期网络库。HTTP/1.1 尤其成熟，HTTP/2 和 TLS 的主体架构也正确。

当前阻碍发布的不是“功能还少”，而是**构建真源、跨层 terminal/ownership、HTTP/2 SETTINGS/flow、security partition 和发布治理尚未闭合**。继续堆功能会扩大修复成本。应先按 PR-A～PR-D 收敛，再冻结 API，最后执行 Linux RC qualification。

**最终评级：**

- 架构质量：A-
- HTTP/1.1 实现：A-
- HTTP/2 实现：B（主体强，但存在三项高严重度跨层缺陷）
- TLS/provider 实现：B+（边界强，session/trust/ownership待收敛）
- 测试与证据工程：B+（丰富但 freshness/独立复现/continuous fuzz 不足）
- CI/仓库治理：D
- Linux 发布就绪度：NO-GO
- 六平台发布就绪度：BLOCKED

---

## 附录 A：机器可读发现登记

- CSV：`wirestack-findings-register-49f3094.csv`
- JSON：`wirestack-findings-register-49f3094.json`

## 附录 B：主要审查文件

`build.cj`、`cjpm.toml`、`scripts/check`、`tools/architecture_guard.py`、`tools/build_linux_tls_provider.py`、`tools/m7_021_linux_release.py`、`tools/m7_025_linux_supply_chain.py`、`.github/workflows/*`、`src/http/*`、`src/tls/*`、`src/internal/{common,transport,transport_stdnet,resolver,connector,trust,tls_engine,http_model,http1,http2,platform}/*`、`native/resolver/linux/*`、`native/tls/aws_lc/*`、`docs/evidence/M7-*`、`docs/api/baselines/*`。
