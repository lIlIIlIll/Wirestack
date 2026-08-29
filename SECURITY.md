# Security policy

## 支持版本

yjson 仅为最新的 2.0.x 补丁版本提供安全修复。旧补丁版本、1.x 候选版本和 pre-1.0
快照不再受支持。请从 [GitHub Releases](https://github.com/lIlIIlIll/yjson/releases/latest)
获取最新稳定版，并查看当前的 [release notes](RELEASE_NOTES.md)。

| Version | Security fixes |
| --- | --- |
| 最新 2.0.x | 支持 |
| 较旧 2.0.x | 升级后支持 |
| 1.x 与 pre-1.0 | 不支持 |

`main` 和 `dev` 是开发分支，不是已发布版本。安全修复完成后，项目通过新的补丁版本交付。

## 私密报告漏洞

使用 GitHub 的 [Report a vulnerability](https://github.com/lIlIIlIll/yjson/security/advisories/new)
提交私密报告。该入口需要 GitHub 账号。

不要在公开 issue、discussion 或 pull request 中提交 exploit、敏感 payload 或未修复漏洞的
细节。报告中请包含以下信息：

- 受影响的版本、tag 或 commit。
- 最小复现和触发条件。
- 可能的影响和攻击前提。
- 已知的缓解方式。

维护者会在私密 security advisory 中确认问题、请求补充信息并协调修复。修复发布后，维护者
可以公开 advisory。项目目前不承诺固定的首次响应或修复时限。

## 处理不可信 JSON

应用应显式配置[资源限制](docs/resource-limits.md)，并在上层提供 framing、并发限流、认证
与授权。`maxBytes` 限制 JSON 文档，不是严格的进程总内存上限。Native backend 扩大了
内存安全审计面，只有完成 sanitizer、fuzz 和生命周期 gate 的平台才可声明 qualified。
