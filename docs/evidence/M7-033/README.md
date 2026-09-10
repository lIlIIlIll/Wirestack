# M7-033 evidence

Current repair status: **IN_PROGRESS**. Local checks and PR builds pass, but the
repaired workflow has not yet deployed from main. The task index is **BLOCKED**
until a new Pages smoke report is bound to a published merge revision. The older
Pages report below is historical evidence, not acceptance of this repair.

M7-033 为 Linux x86_64 glibc 开发者文档与 cjdoc 门禁任务。实现内容包括：

- `docs/guides/getting-started-linux.md` 入门路径和公开 API 使用说明；
- 公开源码声明的 `/** ... */` 注释与参数文档；
- `tools/docs/m7_033_docs.py` 和 `scripts/check-docs` 的分层生成、严格 schema/coverage
  校验、版本锁定和原子报告；
- `docs/api/generated/` 中由 `cjdoc 0.7.2` 生成的 Doc IR、API surface、coverage 和
  Markdown；
- GitHub Actions 中固定 cjdoc release、Pages 部署和有界 HTTP smoke。

本地生成使用 `CJDOC_BIN=/path/to/cjdoc-0.7.2 scripts/check-docs --json`。cjdoc
`v0.7.2` 现已发布在 [GitHub release](https://github.com/lIlIIlIll/cjdoc/releases/tag/v0.7.2)，
Linux x86_64 资产摘要记录在 [`pages-smoke.json`](pages-smoke.json)。当前证据不会把缺失
cjdoc、版本不符、`status=partial`、warning、SKIPPED 或未运行的门禁记录为 PASS。HTML
仅在 `--html` 或 GitHub Pages 工作流中生成到 `target/doc/html/`，不提交到仓库。

机器可读结果：

- [`test-plan.md`](test-plan.md)
- [`docs-report.json`](docs-report.json)
- [`html-report.json`](html-report.json)（本地 Pages HTML staging）
- [`clean-consumer.json`](clean-consumer.json)（运行 clean consumer 后生成）
- [`task-check.json`](task-check.json)（任务级门禁后生成）
- [`pages-smoke.json`](pages-smoke.json)（合并后 GitHub Pages 部署和 HTTP smoke）
- [`evidence.json`](evidence.json)（全部报告通过并封存后生成）

GitHub Actions run `33947870773` 已在合并 SHA
`2f3def83c8903b592faf83edf95a0bc334a94d20` 上成功完成 cjdoc 构建、分层文档生成、
clean consumer、Pages 部署和有界 HTTP smoke。公开站点为
<https://liliilill.github.io/Wirestack/>；根页、`index.html`、`search-index.js` 和首个
API 页面均返回 HTTP 200，精确状态、大小和摘要见 [`pages-smoke.json`](pages-smoke.json)。

未运行：一小时 SSE、86,400 秒 soak 和非 Linux 平台门禁。本任务只声明 Linux x86_64
glibc 文档证据，不将其泛化为其他平台支持。

## CI toolchain repair

The later main-branch run [34370427590](https://github.com/lIlIIlIll/Wirestack/actions/runs/34370427590)
failed before compilation because nightly `1.1.0-alpha.20260414010024` was no
longer available. The historical Pages success above does not cover that run.

Both workflows now select STS `1.1.3` and SDK manager `v0.2.21`. The cjdoc
source remains pinned to `e966097a3591538fba8990772e2e6c543de86c21`. Building and
running cjdoc with the same SDK removes the separate compatibility runtime.
Exact versions and archive digests are recorded in
[`m7-033-ci-toolchain.json`](../../references/m7-033-ci-toolchain.json).

[`ci-toolchain-native.json`](ci-toolchain-native.json) records the successful
native SDK and cjdoc build. Hosted results are recorded by the clean-build and
documentation workflows on the repair's pull request.
The original M8 worktree is separate from this repair; initial branch and base
details are in [`ci-workspace-safety.json`](ci-workspace-safety.json).

Native qualification also exposed a provider-build parser defect: Git's stderr
diagnostic was included in the SHA returned on stdout. The runner now keeps the
streams separate, prints successful diagnostics, and retains both streams in
command failures. A real Git regression fails before the change and passes after
it; adding an untracked file still rejects the provider checkout.

The committed Doc IR and Markdown have also been regenerated from the current
source comments. The API signatures and coverage JSON are unchanged.
[`ci-repair-checks.json`](ci-repair-checks.json) records local validation.
`scripts/check` exited 0 with 588 Cangjie tests passed, 23 skipped and no failures.
The task gate also passed all four commands, including the clean public consumer.

The active main ruleset also requires `report-build-status`. The clean-build
workflow now reports that context only after checking both cjdoc and Wirestack
build results. Failure, cancellation or a skipped prerequisite fails the report;
the branch rules are unchanged.

[`required-checks.json`](required-checks.json) preserves the observed active main
rulesets, including the required `report-build-status` context.
