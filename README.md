# Wirestack

Wirestack 是面向仓颉的安全网络栈，提供独立的 Transport、TLS、HTTPS、
HTTP/1.1 和 HTTP/2 语义，同时保留 `std.net` 作为默认 TCP 与 runtime 调度底座。

当前可验证的产品范围是 **Linux x86_64 glibc**。Transport、DNS、Happy
Eyeballs、TLS 1.2/1.3、HTTP/1.1、HTTP/2、client/server、ALPN、mTLS、SSE
长流和公开取消句柄均已有原生 Linux 证据。六平台产品目标尚未完成，Linux
musl 也要等仓颉 SDK 正式支持后才进入验证。

## 为什么用 Wirestack

- 一个单调绝对 `Deadline` 和一个 `CancellationToken` 贯穿 DNS、连接、TLS、
  HTTP headers 与 body。
- request、connection 和 HTTP/2 stream 有独立、幂等的公开取消句柄。
- TLS provider 在构建时固定为 AWS-LC；默认 Linux 产物不依赖系统 OpenSSL。
- HTTP/1.1 与 HTTP/2 client/server 共用公开 facade；TLS 服务端根据握手保留的
  ALPN 结果分发协议。
- EOF、local close、abort、cancel、deadline、RST 和 TLS truncation 保留不同
  终态；错误使用稳定 category、phase、code 与 retryability。
- parser、buffer、pool、queue、HPACK table、flow-control window 和 session store
  都有明确上限。

Wirestack 不调用 `CJ_MRT_Sock*` 私有 ABI，不自建 epoll/kqueue/IOCP 事件循环，
不从异常文本推断控制流，也不在运行时猜测或回退 TLS provider。

## 安装和首次验证

要求 Linux x86_64 glibc、Cangjie Compiler
`1.1.0-alpha.20260817040003` 和 CJPM `1.1.3`。当前包版本是 `0.1.0`。

```toml
[dependencies]
wirestack = { git = "https://github.com/lIlIIlIll/Wirestack.git" }
```

在仓库 checkout 中准备已固定的本地 native provider 输入，然后运行：

```bash
/home/elliot/.codex/scripts/codex_cangjie_env scripts/repo-doctor
/home/elliot/.codex/scripts/codex_cangjie_env scripts/check-fast
```

完整的安装、native 依赖和第一个 client/server 示例见
[Getting started](docs/getting-started.md)。公开 API 入口见
[API guide](docs/api/README.md)。

## 架构边界

```text
HTTP → TLS → Transport SPI ← StdNetTransport → std.net
```

只有 `wirestack.internal.transport_stdnet` 可以依赖 `std.net`。公开包是
`wirestack.http` 和 `wirestack.tls`；公共 API、TLS Core、HTTP Core 都不暴露
`std.net` 或 provider-native 类型。详细边界和 accepted ADR 见
[Architecture](docs/architecture/README.md)。

## 验证层级

```bash
scripts/check-fast --json
scripts/check-task P1-013 --json
scripts/check-full --json
scripts/check-long M7-022 --json
```

`scripts/check` 保持兼容，执行 Python 测试、架构守卫、native resolver 构建、
`cjpm check`、`cjpm build` 和排除 `Performance` 标签的测试。`check-fast`、
`check-full` 不会隐式启动一小时 SSE、24 小时 soak 或其他长 profile。

## 当前状态

- Linux 功能、fuzz、性能、供应链、API freeze 和迁移示例门禁已完成。
- M7-022 的正式 24 小时最终 soak 正在运行；短 preflight 不能替代它。
- M7-028 至 M7-031 仍依赖 soak、安全审查、签名和最终候选报告。
- 全局 Windows、macOS、Android、iOS、HarmonyOS/OpenHarmony 原生矩阵未完成。
- UP-001 至 UP-007 是远期上游增强，不是 Wirestack 发布依赖。

以 [Linux status](docs/planning/linux-status.md) 和
[task status](docs/planning/status.md) 为当前执行事实；不要从 README 推断发布完成。

## 文档入口

- [Documentation map](docs/README.md)
- [Getting started](docs/getting-started.md)
- [Linux HTTP guide](docs/guides/http1-linux.md)
- [Linux migration guide](docs/guides/migrate-to-wirestack-linux.md)
- [Security](SECURITY.md)
- [Contributing](CONTRIBUTING.md)
- [Product requirements](docs/product/prd.md)
- [Implementation backlog](docs/planning/implementation-backlog.md)

## License and release status

仓库当前版本为 `0.1.0`，尚未通过 Linux 稳定版最终候选门禁。仓库中暂未提供
顶层许可证文件；在许可证正式发布前，不应把源码可见性解释为已授予分发许可。
