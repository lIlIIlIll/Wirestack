# M7-033 evidence

M7-033 为 Linux x86_64 glibc 开发者文档与 cjdoc 门禁任务。实现内容包括：

- `docs/guides/getting-started-linux.md` 入门路径和公开 API 使用说明；
- 公开源码声明的 `/** ... */` 注释与参数文档；
- `tools/docs/m7_033_docs.py` 和 `scripts/check-docs` 的分层生成、严格 schema/coverage
  校验、版本锁定和原子报告；
- `docs/api/generated/` 中由 `cjdoc 0.7.2` 生成的 Doc IR、API surface、coverage 和
  Markdown；
- GitHub Actions 中固定 cjdoc release、Pages 部署和有界 HTTP smoke。

本地生成使用 `CJDOC_BIN=/path/to/cjdoc-0.7.2 scripts/check-docs --json`。当前证据
不会把缺失 cjdoc、版本不符、`status=partial`、warning、SKIPPED 或未运行的 Pages
部署记录为 PASS。HTML 仅在 `--html` 或 GitHub Pages 工作流中生成到
`target/doc/html/`，不提交到仓库。

机器可读结果：

- [`test-plan.md`](test-plan.md)
- [`docs-report.json`](docs-report.json)
- [`html-report.json`](html-report.json)（本地 Pages HTML staging）
- [`clean-consumer.json`](clean-consumer.json)（运行 clean consumer 后生成）
- [`task-check.json`](task-check.json)（任务级门禁后生成）
- [`evidence.json`](evidence.json)（全部报告通过并封存后生成）

未运行：GitHub-hosted Pages 部署、部署后 HTTP smoke、一小时 SSE、86,400 秒 soak
和非 Linux 平台门禁。因 hosted 发布证据尚未取得，状态保持 `IN_PROGRESS`，不得
将本地生成结果泛化为 Pages 或其他平台 PASS。
