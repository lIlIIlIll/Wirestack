# Security policy

## 支持范围

仓库当前处于 1.0 候选阶段；`main` 持续开发，历史 RC 不构成长期支持承诺。具体 release
状态以 `RELEASE_NOTES.md` 与对应 evidence 为准。

## 报告漏洞

不要在公开 issue 中提交 exploit、敏感 payload 或未修复漏洞细节。优先使用代码托管平台
或组织公布的私密安全渠道，并提供：受影响版本/commit、最小复现、影响、触发条件和已知
缓解方式。

本仓库目前没有在本页验证过的专用安全邮箱或 private-report URL。若找不到组织的非公开
渠道，请保留复现材料，等待维护者公布可验证入口；不要创建公开占位 issue。缺少可验证
私密渠道仍是正式 1.0 发布前的流程 blocker。

## 处理不可信 JSON

应用应显式配置[资源限制](docs/resource-limits.md)，并在上层提供 framing、并发限流、认证
与授权。`maxBytes` 限制 JSON 文档，不是严格进程总内存上限；Native backend 还扩大内存
安全审计面，只有完成 sanitizer、fuzz 和生命周期 gate 的平台才可声明 qualified。
