# Wirestack Linux 开发者入门

这份指南面向 Linux x86_64、glibc 上使用 Wirestack 的应用开发者。先跑通仓库
自带的真实示例，再把同样的公开 API 放进自己的 CJPM consumer。当前正式 Linux
TLS provider 是构建期选择的 AWS-LC 5.5.0；本指南不把其他平台或交叉编译称为
已支持。

## 1. 准备环境

需要以下工具：

- Linux x86_64 glibc；
- Cangjie Compiler 1.1.0-alpha 系列和 CJPM 1.1.3；
- Git 和 Python 3；
- 仓库可访问的 AWS-LC 5.5.0 源码/构建输入。

Wirestack 默认 Linux 构建产物不依赖系统 OpenSSL。不要通过环境变量或运行时
动态库探测替换 provider。

```bash
git clone https://github.com/lIlIIlIll/Wirestack.git
cd Wirestack
scripts/repo-doctor --json
```

必需检查项（平台、`cjc`、`cjpm` 和仓库检查）必须为 `PASS`。整体结果为
`READY` 时可以继续；如果输出 `BLOCKED`，先修复它列出的工具链或平台能力。
`DEGRADED` 表示可选能力（例如 GitButler 状态读取）不可用，不能当作发布或文档
`PASS`，但不等同于 Wirestack 编译失败。

## 2. 先运行官方示例

官方示例覆盖 HTTP/1.1、SSE、分作用域取消、CONNECT 配置、HTTPS、custom CA、
HTTP/2、已有 transport TLS 和 mTLS。运行统一的干净 consumer 门禁：

```bash
scripts/check-m7-027-linux-examples --json
```

成功输出必须包含以下九个标记，且不能出现 `SKIPPED`：

```text
HTTP1_SERVER=PASS
SSE=PASS
SCOPED_CANCELLATION=PASS
CONNECT_TLS=PASS
HTTPS_CLIENT=PASS
CUSTOM_CA=PASS
HTTP2_SERVER=PASS
EXISTING_TRANSPORT_TLS=PASS
MTLS=PASS
```

这一步会构建当前 Linux provider 和 resolver，并在临时 consumer 中编译、运行
示例。它比直接在仓库源码目录运行更接近应用使用方式。

## 3. 最小 HTTPS client

应用只需要导入公开包。下面的 client 使用系统信任库；需要固定 CA 时，把
`HttpClientTlsConfig` 传给 builder，具体字段见 [API 参考](../api/README.md)。

```cj
package hello_wirestack

import std.time.Duration
import wirestack.http.*

main(): Int64 {
    let client = HttpClient.builder()
        .requestTimeout(10 * Duration.second)
        .build()
    try {
        let response = client.get("https://example.com/")
        try {
            println("status=${response.status} version=${response.version}")
            let buffer = Array<Byte>(16 * 1024, repeat: 0u8)
            while (response.body.read(buffer) > 0) {}
            0
        } finally {
            response.close()
        }
    } catch (error: Exception) {
        eprintln("request failed: ${error}")
        1
    } finally {
        client.close()
    }
}
```

生产代码应显式传递同一个 `OperationContext`，例如
`OperationContext(deadline: Some(Deadline.after(10 * Duration.second)))`，让
DNS、连接、TLS、HTTP 和 body 共享一个单调绝对预算。`HttpResponse` 使用完必须
关闭或读到 EOF，才能安全归还连接池。

## 4. 最小 HTTP server

server handler 只处理公开的 request/response 类型。下面的 cleartext server
展示最小形状；把 `HttpServerTlsConfig` 传给 `.tls(...)` 即可启用 HTTPS，并由
ALPN 在 HTTP/1.1 与 HTTP/2 之间 dispatch。

```cj
package hello_wirestack_server

import std.time.Duration
import wirestack.http.*

class Handler <: HttpServerHandler {
    public func handle(request: HttpServerRequest,
        context: OperationContext): HttpServerResponse {
        let _ = context
        let _ = request.body.read(Array<Byte>(1, repeat: 0u8))
        let body = RequestBody.bytes("ok".toArray()).open()
        HttpServerResponse(HttpResponse(
            200,
            "OK",
            ResponseBody(body),
            headers: HttpHeaders.builder()
                .add("Content-Length", "2")
                .build()
        ))
    }
}

main(): Int64 {
    let loopback = IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8])
    let server = HttpServer.builder()
        .listen(SocketEndpoint(loopback, 8080))
        .handler(Handler())
        .build()
    let serving = spawn { server.serve() }
    try {
        println("server is listening")
        let context = OperationContext(
            deadline: Some(Deadline.after(5 * Duration.second)))
        let _ = server.shutdown(context: context)
        serving.get(5 * Duration.second)
        0
    } catch (error: Exception) {
        eprintln("server failed: ${error}")
        1
    } finally {
        server.close()
    }
}
```

真实应用应在 shutdown 前停止接收新工作，并保留 `Future` 的 join。服务端 TLS
证书链使用 leaf-first DER，私钥使用 PKCS#8 DER；不要把 native provider handle
或 `wirestack.internal.*` 类型带入 handler。

## 5. 继续阅读

- [HTTP client/server 深入指南](http1-linux.md)：代理、stream body、重试和分作用域取消；
- [Linux 迁移指南](migrate-to-wirestack-linux.md)：从旧 timeout、CA、mTLS 和错误处理迁移；
- [公开 API 参考和生成说明](../api/README.md)：`cjdoc 0.7.2`、API surface、coverage 和 Pages；
- [架构与 ADR](../architecture/README.md)：Transport/TLS/HTTP 依赖方向和 provider 选择约束。

API 文档只描述当前 pre-1.0 Linux 公开契约。版本 1.0 前不承诺实验性 API 的
source、API、ABI 或语义兼容；请以仓库中本次提交生成的 API surface 为准。
