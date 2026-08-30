# M7-029 independent security review

Decision: PASS for the Linux x86_64 glibc M7-029 security gate.

I reviewed package `9d4c4676cd52883aa002e20946b474ac2777d7fcee2bcfe9c232436c44aeaf82` from an immutable no-history snapshot. All 2 Critical and 14 High findings remain Fixed. No Critical or High finding is open.

The two M3-030 native ABI findings were not carried forward on the old attachment. I rechecked the 56-function schema-v2 contract, production Cangjie import discovery, archive-symbol enforcement, Cangjie signature comparison, compiled native-header probe, fail-closed platform/provider selection, and the negative mutation tests. The regenerated pinned-20260817 task record is now bound by its exact SHA-256, `20d8509d3104369903e074044dde893b4ed18622ef47d4acb9bc87850b505610`. It records all six M3-030 commands as PASS, including `cjpm check` and 592 non-performance tests with 569 passed, 23 explicit skips, and no failures or errors.

One Medium finding, `WS-EVID-002`, remains open. Final-candidate release, SBOM, installation, audit, performance, SSE, and 24-hour soak evidence must still be regenerated or run by their owning release tasks. I did not run the one-hour SSE profile, 24-hour soak, SDK build, non-Linux gates, or Cangjie commands that would write into the immutable snapshot.

The snapshot has no `.git` metadata. One bounded M7-029 unit test therefore returned 1 because its tracked-file assertion expected Git's normal return code 1 but received 128 for "not a git repository". The other 13 cases in that module passed. I treated the provider manifest's tracked-file status and GitHub ruleset as preserved-evidence claims, not live observations. Their exact evidence digests match the report.
