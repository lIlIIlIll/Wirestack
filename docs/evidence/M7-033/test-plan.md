# M7-033 测试计划：cjdoc 开发者文档与发布门禁

本任务只验收 Linux x86_64 glibc 的公开 Wirestack 文档。HTML 是由 CI 从同一
份 Doc IR 生成的发布物；不会把本地低资源或其他 `cjdoc` 版本的结果记录为
PASS。

## Control-flow paths

| Path ID | Condition | Terminal |
|---|---|---|
| P001 | `cjdoc` 版本精确为 0.7.2，且命令成功 | PASS |
| P002 | `cjdoc` 缺失、版本不符或参数错误 | BLOCKED/FAIL |
| P003 | 任一分层 Doc IR 缺失、`status=partial` 或含诊断 | FAIL |
| P004 | 公开符号或参数覆盖率低于 100% | FAIL |
| P005 | API surface、Doc IR、coverage、Markdown 通过 schema 和摘要校验 | PASS |
| P006 | 输出目录越界、覆盖非 cjdoc 所有内容或原子写入失败 | FAIL |
| P007 | clean consumer 仅导入公开包并运行 HTTPS 示例 | PASS |
| P008 | Pages 生成、部署或有界 HTTP smoke 失败 | FAIL |
| P009 | 长任务被 fast/full 隐式执行，或 SKIPPED 被记为 PASS | FAIL |
| P010 | 源码、工具链或生成输入摘要变化 | STALE |

## Semantics and scenario matrix

| Scenario ID | Input/condition | Paths |
|---|---|---|
| S001 | Linux x86_64 glibc + exact `cjdoc 0.7.2` | P001,P005 |
| S002 | missing `cjdoc`, 0.7.1, unknown CLI option | P002 |
| S003 | root/http/tls 分层生成 | P001,P003,P004,P005 |
| S004 | fallback Doc IR with `status=partial` | P003 |
| S005 | unknown schema or malformed JSON | P003,P005 |
| S006 | coverage has `SKIPPED`, missing symbol or missing parameter | P004 |
| S007 | output path escapes repository or atomic replacement is injected to fail | P006 |
| S008 | clean consumer imports `wirestack.http`/`wirestack.tls` only | P007 |
| S009 | long-running profile appears in fast/full command set | P009 |
| S010 | source or cjdoc version digest no longer matches evidence | P010 |
| S011 | Pages artifact/deploy and bounded root/API/search smoke | P008 |

## Test-plan matrix

| Test ID | Scenarios | Paths | Verification |
|---|---|---|---|
| T001 | S001,S002 | P001,P002 | fake/real executable version resolver and stable exit code |
| T002 | S003,S004,S005 | P003,P005 | Doc IR validator rejects partial, unknown schema and diagnostics |
| T003 | S006 | P004 | API/coverage validator requires 100% symbols and parameters |
| T004 | S007 | P006 | safe-path and atomic-report fault injection |
| T005 | S008 | P007 | existing M7-027 clean-consumer gate and public-import scan |
| T006 | S009 | P009 | task manifest/repository tooling long-gate isolation |
| T007 | S010 | P010 | evidence source/output digest freshness check |
| T008 | S011 | P008 | CI workflow validation and bounded HTTP smoke contract |
| T009 | S001,S003 | P001,P003,P004,P005 | exact 0.7.2 layered generation and committed artifact validation |

未运行的一小时 SSE、86,400 秒 soak 和非 Linux 平台门禁不属于本任务验收。
