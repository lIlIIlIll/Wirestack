# Windows resource-growth remediation

The native Windows run `33602643549` completed the four-hour workload but
failed its resource trend. Handles grew by `244` against a limit of `8`, and
private bytes grew by `65068 KiB` against a limit of `8192 KiB`. The process
RSS and socket/thread counts did not show the same sustained growth. The
report remains unchanged under `windows-x86_64/long-4h.json`.

The stress probe creates a short-lived socket and, for the close-during-read
case, a short-lived asynchronous reader on every cycle. The failed Windows
profile is consistent with completed asynchronous objects or native wrappers
waiting for a collection cycle. The Windows gate now generates a Windows-only
probe variant with an optional fourth argument, `gcEvery`, and supplies the
fixed value `256`. The collection happens after the iteration's close and join
operations. Linux gate commands still compile the unchanged shared probe, so
this mitigation does not change the Linux workload contract or its source
digest.

The Windows validator records and requires the value in both the probe result
and the structured workload report. A report that omits the cadence or claims
a different value fails with `PROBE_CLEANUP`.

## Local checks

- `python3 -m unittest tools.gates.tests.test_m0_011_windows_long -v`: 11/11
  passed.
- The generated probe compiled with the local Cangjie compiler (`cjc` exit 0).
- A 20-second loopback smoke run using the Windows probe variant with
  `gcEvery=256` completed 45,932
  iterations, exited 0, and reported a PASS resource trend. This is only a
  compile/smoke check, not Windows evidence.

## Still required

A fresh native `windows-2025` four-hour run at the exact post-fix revision must
show PASS resource trends before the Windows supplemental gate can close. No
new four-hour run was started in this local change, and no threshold was
weakened.
