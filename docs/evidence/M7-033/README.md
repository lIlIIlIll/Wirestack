# M7-033 evidence

Current repair status: **COMPLETE**. [PR #155](https://github.com/lIlIIlIll/Wirestack/pull/155)
merged as `ec2e8236625c5f45625750c1a4ed947f2dcf8c9c`. The repaired main workflow
deployed successfully; the new Pages smoke report is bound to that published
revision. This acceptance records that revision, not subsequent source changes.

M7-033 为 Linux x86_64 glibc 开发者文档与 cjdoc 门禁任务。实现内容包括：

- `docs/guides/getting-started-linux.md` 入门路径和公开 API 使用说明；
- 公开源码声明的 `/** ... */` 注释与参数文档；
- `tools/docs/m7_033_docs.py` 和 `scripts/check-docs` 的分层生成、严格 schema/coverage
  校验、版本锁定和原子报告；
- `docs/api/generated/` 中由 `cjdoc 0.7.2` 生成的 Doc IR、API surface、coverage 和
  Markdown；
- GitHub Actions 中固定 cjdoc 源码构建、Pages 部署和有界 HTTP smoke。

本地生成使用 `CJDOC_BIN=/path/to/cjdoc-0.7.2 scripts/check-docs --json`。cjdoc
`v0.7.2` 现已发布在 [GitHub release](https://github.com/lIlIIlIll/cjdoc/releases/tag/v0.7.2)，
固定 SDK 和 cjdoc 源码摘要见 [`m7-033-ci-toolchain.json`](../../references/m7-033-ci-toolchain.json)。
当前证据不会把缺失 cjdoc、版本不符、`status=partial`、warning、SKIPPED 或未运行的门禁记录为 PASS。HTML
仅在 `--html` 或 GitHub Pages 工作流中生成到 `target/doc/html/`，不提交到仓库。

机器可读结果：

- [`test-plan.md`](test-plan.md)
- [`docs-report.json`](docs-report.json)
- [`html-report.json`](html-report.json)（历史本地 HTML staging，不作为当前修复验收）
- [`clean-consumer.json`](clean-consumer.json)（运行 clean consumer 后生成）
- [`task-check.json`](task-check.json)（任务级门禁后生成）
- [`pages-smoke.json`](pages-smoke.json)（合并后 GitHub Pages 部署和 HTTP smoke）
- [`evidence.json`](evidence.json)（全部报告通过并封存后生成）

GitHub Actions run [34437634186](https://github.com/lIlIIlIll/Wirestack/actions/runs/34437634186)
已在合并 SHA `ec2e8236625c5f45625750c1a4ed947f2dcf8c9c` 上完成 cjdoc 构建、
分层文档生成、clean consumer、Pages 部署和有界 HTTP smoke。公开站点为
<https://liliilill.github.io/Wirestack/>；根页、`index.html`、`search-index.js` 和首个
API 页面均返回 HTTP 200。运行、提交和 HTTP 状态见 [`pages-smoke.json`](pages-smoke.json)。

未运行：一小时 SSE、86,400 秒 soak 和非 Linux 平台门禁。本任务只声明 Linux x86_64
glibc 文档证据，不将其泛化为其他平台支持。

## CI toolchain repair

The later main-branch run [34370427590](https://github.com/lIlIIlIll/Wirestack/actions/runs/34370427590)
failed before compilation because nightly `1.1.0-alpha.20260414010024` was no
longer available. The earlier deployment did not qualify the repaired toolchain.

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
build results. Failure, cancellation or a skipped prerequisite fails the report.

The documentation workflow also requires `report-docs-status`, which checks both
its cjdoc build and documentation generation results. A skipped Pages deployment
on a pull request is not used as proof that documentation generation succeeded.

[`required-checks.json`](required-checks.json) records the verified main rulesets.
The user explicitly removed the unavailable GitHub Code Quality rule and its
dependent built-in coverage rule. CodeQL, build/documentation checks, review
requirements and other branch protections remain active; no bypass was used.
CodeQL default setup passed for Actions, C/C++ and Python. It does not analyze
Cangjie.

Pages deployment is limited to pushes to `main`. The workflow uploads an atomic
JSON smoke report bound to that run's commit, rather than relying on a historical
deployment report. The exact HTTP script passed local fixture checks for four
HTTP 200 responses; HTTP 404, HTTP 204 and a stalled response failed without
publishing a PASS report. The bounded timeout and results are recorded in
[`ci-repair-checks.json`](ci-repair-checks.json). The main deployment's unmodified
smoke artifact is now recorded in [`pages-smoke.json`](pages-smoke.json).

GitHub Pages now uses `build_type=workflow`, removing the competing legacy
`main:/docs` publisher. HTTPS and the public URL are unchanged. A live browser
check searched for `Deadline`, opened `wirestack.Deadline — struct`, and reached
the `wirestack.Deadline` reference page. Configuration and browser observations
are recorded in [`required-checks.json`](required-checks.json).
