# 公开 API 导览

Wirestack 对应用开发者公开 `wirestack.http` 和 `wirestack.tls`。`wirestack.internal.*`
是实现细节，consumer 不应导入。Linux 入门路径见
[getting-started-linux.md](../guides/getting-started-linux.md)。

最新生成的 HTML 会发布到
[`lIlIIlIll.github.io/Wirestack`](https://lIlIIlIll.github.io/Wirestack/)。Pages workflow
从 `main` 重新生成站点；HTML 不提交到仓库。

## 生成和校验 API 参考

仓库固定使用 `cjdoc 0.7.2`。版本不符、找不到可执行文件、Doc IR 不完整、存在
warning、schema 未知或覆盖率低于 100% 都会使门禁失败。命令会先建立只包含公开
源码的临时视图，分别校验每个公开包，再写入 JSON 和 Markdown 投影：

```bash
CJDOC_BIN=/path/to/cjdoc-0.7.2 scripts/check-docs --json
```

命令写入以下可提交产物：

```text
docs/api/generated/docs.json
docs/api/generated/api-surface.json
docs/api/generated/coverage.json
docs/api/generated/markdown/
```

需要本地预览 HTML 或准备 Pages staging 时加 `--html`；输出位于
`target/doc/html/index.html` 和 `target/doc/html/search-index.js`：

```bash
CJDOC_BIN=/path/to/cjdoc-0.7.2 scripts/check-docs --html --json
```

仓库级 `scripts/check` 也会调用文档门禁。长时间 profile 不会被文档检查隐式触发。

## `wirestack.http`

使用 `HttpClient` 和 `HttpServer` 处理 HTTP/1.1 与 HTTP/2。facade 在同一个
`OperationContext` 下管理路由、DNS、Happy Eyeballs、可选 CONNECT、TLS、ALPN、连接池
和 body 生命周期。

常用类型包括 `HttpClient`、`HttpServer`、`HttpRequest`、`HttpResponse`、
`HttpClientTlsConfig`、`HttpServerTlsConfig`、`HttpBodyStream`、`RequestBody`、
`ResponseBody`，以及 request/connection/stream cancellation handle。响应 body 必须
读到 EOF 或显式关闭，连接才能安全归还连接池。

详细流程见 [Linux HTTP 指南](../guides/http1-linux.md)。

## `wirestack.tls`

当 TLS 包裹调用方拥有的 `DuplexTransport` 时，使用 `TlsClientContext` 或
`TlsServerContext`。context 构建后不可变，也不会暴露 AWS-LC handle。信任策略、
reference identity、本地身份、外部签名和 transport 所有权都是独立的类型化契约。

`TlsRuntime.info()` 返回只读的 provider/build 诊断，展示构建期选择，不会运行时选择
或替换 provider。

## 稳定性和所有权

[M7-032 Linux pre-1.0 inventory](baselines/wirestack-linux-pre1-m7-032.json) 记录
当前公开契约；较早的 [M7-026 snapshot](baselines/wirestack-linux-v0.json) 仅作为历史
证据，不是兼容性目标。1.0 之前，Wirestack 不承诺实验性 API 的 source、API、ABI 或
语义兼容。

- 包装 transport 会把它的使用权转交给 TLS connection；
- `close` 和 `abort` 幂等；
- 一个 read 和一个 write 可以并行，同方向重叠会失败；
- 子任务可以缩短 deadline，但不能延长；
- custom roots 不会关闭 reference-identity 校验；
- HTTP 4xx/5xx 是 response，不是 transport exception。

完整的 public-only 可运行 consumer 位于
[`examples/linux/m7_027`](../../examples/linux/m7_027/)。源码声明是精确签名参考。

校验当前 API inventory：

```sh
scripts/check-m7-032-public-api --json
```

该门禁校验公开所有权，并拒绝指向 internal package 的 alias。
