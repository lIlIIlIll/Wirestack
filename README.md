# Wirestack

Wirestack 是一个面向仓颉的跨平台安全网络栈项目，目标是在保留 `std.net` 作为官方默认 TCP/runtime 调度底座的前提下，重新定义并实现独立的 Transport、TLS、HTTPS、HTTP/1.1 与 HTTP/2 语义。

当前仓库处于 **M0 架构与采纳验证阶段**。现有 TLS/HTTP/std.net 已完成盘点，真实 CJPM 包布局已经冻结并可构建；尚未宣称任何 Transport、TLS、HTTP 或六平台运行能力已经实现。

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

这些包目前仅建立编译边界，没有占位公共 API。

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

当前统一检查执行 `cjpm check` 和 `cjpm build`。后续任务会在同一入口增加架构守卫和测试。

SDK 归档、解压后的工具链和 `target/` 构建产物都不进入仓库。

## 文档

- [产品 PRD](docs/product/prd.md)
- [仓库实施 backlog](docs/planning/implementation-backlog.md)
- [执行状态](docs/planning/status.md)
- [架构与 ADR](docs/architecture/README.md)
- [现有网络栈盘点](docs/architecture/current-network-stack-inventory.md)
- [CJPM 包布局 ADR](docs/architecture/adr/0001-cjpm-package-layout.md)
- [采纳与发布门禁](docs/gates/README.md)
- [任务证据约定](docs/evidence/README.md)
- [SDK 检查记录](docs/references/cangjie-sdk-1.1.0-alpha.20260817040003.md)
- [Codex/Agent 仓库规则](AGENTS.md)

## 当前执行点

Linux Transport/Resolver/Connector 基础实现已经形成三个本地提交。M0-016 保留的 AWS-LC Linux glibc/musl schema-v2 结果均为 `PASS`，包含 TLS 1.2/1.3 external signer 和各 10,000 次 handshake/close；ADR-0003 因此冻结 Linux 默认 provider。全局 M0-016/M0-020 仍因 Windows、macOS external signer 与移动平台证据缺失而保持 `BLOCKED`。当前 Linux 关键路径进入 AWS-LC 静态集成与 TLS Core 实现。

不要把“能交叉编译”视为平台支持完成；涉及平台能力的完成声明必须有真机或原生 VM 证据。
