# M8-001 evidence

Status: IN_PROGRESS. This isolated publication reconstructs the M8-001 contract
from the cumulative workspace. Exact early source snapshots were unavailable.
The reports under `historical/` describe the previous source and are not PASS
evidence for this reconstruction.

## Scope

- Public `wirestack.net` endpoint, lifecycle, context, option-value and capability
  contracts, with a TCP stream bridge to the existing Transport SPI.
- Explicit Unix/raw capability boundaries. Address construction does not prove
  native adapter support.
- Initial provider-neutral HTTP parity value and hook contracts. Client/server
  integration remains M8-005 work.
- Public API inventory, complete API documentation, negative tests and bounded
  DNS-header mutation coverage.

The publication worktree is separate from the original dirty workspace. See
`workspace-safety-publication.json` for the branch, base, platform and toolchain
commands. The original files and index are not publication inputs to Git.

## Acceptance

Fresh task commands and the canonical `scripts/check` must pass before this
entry becomes COMPLETE. The task manifest uses `cjpm` from the configured PATH,
matching accepted repository conventions rather than a developer-specific
absolute wrapper path. Exact commands, exit statuses and raw logs will be
recorded beside their JSON reports and bound by `evidence.json`.

M8-002 owns native TCP/UDP listener, socket options and wakeup evidence; M8-003
owns Unix/raw native capability evidence; M8-004 owns full DNS. No privileged raw
I/O, non-Linux execution, later protocol integration or long soak is claimed.
