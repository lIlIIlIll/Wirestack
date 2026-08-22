# Wirestack

Wirestack 是一个面向仓颉的跨平台安全网络栈项目，目标是在保留 `std.net` 作为官方默认 TCP/runtime 调度底座的前提下，重新定义并实现独立的 Transport、TLS、HTTPS、HTTP/1.1 与 HTTP/2 语义。

当前仓库处于 **pre-M0 / bootstrap** 状态：只有产品、架构和实施控制面，尚未宣称任何 TLS、HTTP 或六平台运行能力已经实现。

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

只有 `StdNetTransport` 适配层允许依赖 `std.net`。TLS Core、HTTP Core 与公共 API 不得导入或暴露 `std.net` 类型。

## 文档

- [产品 PRD](docs/product/prd.md)
- [仓库实施 backlog](docs/planning/implementation-backlog.md)
- [执行状态](docs/planning/status.md)
- [架构与 ADR](docs/architecture/README.md)
- [采纳与发布门禁](docs/gates/README.md)
- [任务证据约定](docs/evidence/README.md)
- [外部环境记录](docs/references/environment.md)
- [Codex/Agent 仓库规则](AGENTS.md)

## 当前执行点

仓库 bootstrap 完成后，从 **M0-001：盘点现有 TLS/HTTP/std.net 实现与依赖图** 开始。M0 的目标是先获得六平台 `std.net` 采纳证据、TLS provider PoC、Transport SPI 和 threat model，再进入正式数据路径实现。

不要把“能交叉编译”视为平台支持完成；涉及平台能力的完成声明必须有真机或原生 VM 证据。
