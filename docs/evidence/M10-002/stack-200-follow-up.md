# M10-002 Stack #200 follow-up

This report records the Stack #200 resource-owner/backpressure follow-up on the current M10-002 implementation. The original acceptance report remains `verification.json`; this report does not replace its historical SDK 1.1.3 evidence.

## Scope

- HTTP/2 frame input is consumed incrementally and dispatched before parsing a later frame from the same read; completed buffer reservations are released on exceptional exits.
- HTTP/2 DATA queue admission carries the canonical `OperationContext`, uses the control owner for control frames and stream owner for DATA, and releases buffer leases/flow permits on rejection or cancellation.
- Server HTTP/2 DATA ownership uses the validated scheme and authority. Push stream exhaustion is nonblocking and rejects/cleans the pushed response without delaying the parent response.
- Dynamic proxy authorization credentials share aggregate route admission while remaining distinct pool/security keys.
- Public facade regressions exercise the proxy admission, server-origin buffer attribution, and push-at-stream-limit behaviors.

No public API was added or changed.

## Environment and commands

Linux x86_64 glibc; Cangjie SDK `1.3.0-alpha.20261010001050`, CJPM `1.3.0-alpha.06`. This SDK was available for smoke validation; SDK 1.1.3 requalification was not available. Validation commands used `$HOME/.codex/scripts/codex_cangjie_env`, `DISABLE_ZOXIDE=1`, and `TMPDIR`, `TMP`, and `TEMP` set to a disk-backed task directory (normalized below as `<task-tmp>`).

| Command | Result |
|---|---|
| `scripts/architecture-guard` | Exit 0; PASS. |
| `cjpm check` | Exit 0; PASS for all packages. |
| `cjpm build` | Exit 0; PASS. Existing warnings remain, including one unreachable expression in `src/internal/http_resource_budget.cj` and unused test/runtime helpers; no compile errors. |
| `cjpm test --parallel 1 --no-progress --no-color src/internal/http2` | Exit 0; 204 passed, 0 skipped, 0 errors, 0 failed. |
| `cjpm test --parallel 1 --no-progress --no-color src/internal/http1` | Mixed: one full run passed 169/169; three full runs exited 1 with 168 passed and one `ERROR`. The isolated failing case passed 1/1 on both observed reruns. |
| `cjpm test --parallel 1 --no-progress --no-color src/http` | Final full run exited 0: 165 passed, 0 skipped, 0 errors, 0 failed. One earlier post-cleanup full run exited 1 with 164 passed and one failure; the isolated case passed 1/1. |
| `cjpm test --filter='HttpFacadeTest.authenticatedProxyCredentialsShareRouteAdmission,HttpFacadeTest.http2RequestDataUsesTheValidatedServerOriginOwner,HttpFacadeTest.http2PushAtTheStreamLimitDoesNotBlockItsParent' --parallel 1 --no-progress --no-color src/http` | Exit 0; 3 passed, 162 skipped, 0 errors, 0 failed. |
| `cjpm test --filter='Http2ConnectionPoolTest.saturatedCrossOriginWaiterDrainsHttp2ConnectionBeforeSameKeyRefill' --parallel 1 --no-progress --no-color src/internal/http1` | Exit 0; isolated case passed 1/1 on both observed isolated reruns. |

Across four final-tree `src/internal/http1` full-suite invocations, one passed all 169 cases and three returned 168 passed plus one `ERROR`. Each error was `Http2ConnectionPoolTest.saturatedCrossOriginWaiterDrainsHttp2ConnectionBeforeSameKeyRefill`, which timed out awaiting `otherOrigin.get(Duration.second)`. The isolated case passed 1/1 on both observed reruns. The pool implementation and test were not changed in this follow-up.

After the final wrapper cleanup, one full `src/http` run failed at `HttpClientExtensionsTest.closingClientWakesStalledConnectorConnectionAdmission`: `secondRejected` was false. Its isolated run passed 1/1, and the next full run on the same tree passed all 165 cases. A full `src/http` run before that cleanup also passed all 165 cases.

Treat the intermittent full-suite failures as observed results, not unconditional passes.
The repository-wide `scripts/check` run previously stopped in its initial tooling unittest command: 585 tests, 25 failures, 16 errors, 4 skipped, exit 1. It did not reach the later architecture/documentation/Cangjie checks. Observed baseline failures included stale AWS-LC advisory disposition, M12-002 platform error mismatch, M3-031 expected error-code mismatch, and M7 task-graph expectation drift. The independent architecture guard, `cjpm check`, and `cjpm build` above pass.

The previously recorded strict documentation check remains blocked before generation because installed `cjdoc` is 0.7.1 while the repository requires 0.7.2. No other platform is claimed. GitHub issue #174 was not updated.

## Stack #200 PR clean-build source-tree mutation

Pre-sync PR #216 head `182f12e489787ffa7d4692bfe7fe130f2d920fb2` failed only at the final source-tree mutation step ([Clean Cangjie Build run 39318412391](https://github.com/lIlIIlIll/Wirestack/actions/runs/39318412391)): `scripts/check-code` and the installed public-consumer build had completed successfully, but `scripts/check-docs` rewrote tracked `docs/api/generated/docs.json`. `report-build-status` then failed with `CJDOC_RESULT=success` and `WIRESTACK_RESULT=failure`. The separate architecture, harness, pinned-cjdoc build, and API-doc generation checks passed at that PR head; the latest-main docs deployment was skipped.

Using the run's pinned `cjdoc 0.7.2` artifact and the Cangjie/CJPM 1.1.3 wrapper on Linux x86_64 glibc, the exact documentation command passed:

```sh
<qualified-wrapper> --sdk-root <qualified-sdk> --cwd <repo> -- \
  scripts/check-docs --json --output build/check-docs.json
```

Exit: 0. Combined API documentation coverage: 1,873/1,873 symbols and 950/950 parameters. The regenerated `docs/api/generated/docs.json` SHA-256 is `1fde2a6cc279ae78347a2013f698fc97303c41e5400e5825a871f0834e1b86c1`. After the generator completed and before this report update, `but diff` showed `docs/api/generated/docs.json` as its only changed tracked path. The child follow-up carries this generated output so the clean-build gate can verify a source tree already synchronized with the pinned generator. This does not resolve the separately recorded HTTP/1 fairness nondeterminism or the PR's incomplete Q4 permit/lease ordering. The post-sync CI result remains attached to PR #216.

## Evidence boundary

These results validate the Stack #200 follow-up on Linux x86_64 with the available SDK as smoke evidence. They do not requalify SDK 1.1.3, establish other-platform support, or clear the repository-wide tooling/documentation blockers. The intermittent HTTP/2 connection-pool fairness test remains outside this M10-002 follow-up and requires a separate scoped investigation if it persists.