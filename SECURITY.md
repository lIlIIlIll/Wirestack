# Security policy

## Supported versions

安全修复以当前 2.x release line 为主。尚未发布的 release candidate 不代表长期支持承诺；
具体版本状态以 release notes 为准。

## Reporting a vulnerability

请优先使用代码托管平台提供的私密安全报告渠道，并提供受影响版本、最小复现、影响与已知
缓解方式。不要在公开 issue 中提交 exploit、敏感 payload 或未修复漏洞细节。

本仓库当前没有在文档中公布专用安全邮箱。如果托管平台没有私密报告入口，可先创建一个
不含漏洞细节的 issue，请维护者提供私密联络方式；在渠道确认前保留完整复现。

处理不可信 JSON 时应显式设置 [资源限制](docs/resource-limits.md)。这些限制降低资源滥用
风险，但 `maxBytes` 不是严格的进程总内存上限，也不能替代协议 framing、并发限流与上层
认证授权。
