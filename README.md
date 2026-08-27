# Wirestack

Wirestack 是一个面向仓颉的跨平台安全网络栈项目，目标是在保留 `std.net` 作为官方默认 TCP/runtime 调度底座的前提下，重新定义并实现独立的 Transport、TLS、HTTPS、HTTP/1.1 与 HTTP/2 语义。

当前仓库已完成 Linux glibc 上的 Transport、Resolver、Connector、TLS、HTTP/1.1 与 HTTP/2 主体实现和验收。AWS-LC 5.5.0 是 Linux provider。公开 cancellation handles、HTTP/2 server facade、ALPN dispatch 和一小时 SSE profile 已有 native Linux 证据。ADR-0004 将 musl 延后到 SDK 正式支持之后。ADR-0005 规定 Wirestack release 不依赖 runtime 或 `std.net` 源码修改；缺少 typed TCP half-close、native socket code 或精确 runtime backend 时，适配器使用稳定的能力和错误表示。

## 目标

- Windows、Linux、macOS、Android、iOS、HarmonyOS/OpenHarmony 的 HTTPS 客户端。
- 独立 Transport SPI，隔离现有 `std.net` 的 DNS、timeout、EOF、错误和公共类型语义。
- TLS 1.2/1.3、系统信任、自定义 CA、mTLS、session resumption、ALPN/SNI。
- HTTP/1.1 与 HTTP/2 client/server。
- 单调绝对 Deadline、统一 CancellationToken、结构化错误和 exactly-once completion。
- 官方默认发布产物不要求用户安装或管理系统 OpenSSL。

## 非目标

P0 不包含 HTTP/3/QUIC、DTLS、TLS 1.0/1.1、0-RTT、PAC/WPAD、DoH/DoT，也不会在第一阶段重写整个 `std.net`。

Wirestack 不直接调用 `CJ_MRT_Sock*` 私有 ABI，不自行实现六套 epoll/kqueue/IOCP 事件循环，也不通过运行时猜测动态库来选择 TLS provider。

## 架构边界

```text
HTTP → TLS → Transport SPI ← StdNetTransport → std.net
```

只有 `wirestack.internal.transport_stdnet` 允许依赖 `std.net`。TLS Core、HTTP Core 与公共 API 不得导入或暴露 `std.net` 类型。

已冻结的主要包：

```text
wirestack.tls
wirestack.http
wirestack.internal.transport
wirestack.internal.transport_stdnet
wirestack.internal.resolver
wirestack.internal.connector
wirestack.internal.tls_engine
wirestack.internal.trust
wirestack.internal.identity
wirestack.internal.http1
wirestack.internal.http2
wirestack.internal.platform.*
```

Transport、Resolver、Connector、TLS、HTTP/1.1 与 HTTP/2 包已经包含 Linux glibc 实现。全平台发布矩阵仍未完成。

## 本地验证

已验证工具链：

```text
Cangjie Compiler: 1.1.0-alpha.20260817040003 (cjnative)
Cangjie Project Manager: 1.1.3
```

使用仓颉 SDK：

```bash
source /path/to/cangjie/envsetup.sh
./scripts/check
```

当前统一检查执行架构守卫、构建和测试。长期 profile 和部分 native gate 由各任务的证据命令单独运行。

SDK 归档、解压后的工具链和 `target/` 构建产物都不进入仓库。

## 文档

- [产品 PRD](docs/product/prd.md)
- [仓库实施 backlog](docs/planning/implementation-backlog.md)
- [执行状态](docs/planning/status.md)
- [Linux-first 执行状态](docs/planning/linux-status.md)
- [架构与 ADR](docs/architecture/README.md)
- [现有网络栈盘点](docs/architecture/current-network-stack-inventory.md)
- [CJPM 包布局 ADR](docs/architecture/adr/0001-cjpm-package-layout.md)
- [采纳与发布门禁](docs/gates/README.md)
- [任务证据约定](docs/evidence/README.md)
- [SDK 检查记录](docs/references/cangjie-sdk-1.1.0-alpha.20260817040003.md)
- [Codex/Agent 仓库规则](AGENTS.md)

## 当前执行点

Linux glibc 主体能力已经完成。当前关键路径是 M1-024 确定性竞态测试、M1-025 泄漏与 benchmark 收口，以及 Linux 专用的 M7 发布任务。UP-001 至 UP-007 都是远期上游增强，不在 Wirestack 发布依赖图中。全局六平台状态仍因其他平台的原生证据缺失而保持 fail-closed。

不要把“能交叉编译”视为平台支持完成；涉及平台能力的完成声明必须有真机或原生 VM 证据。
