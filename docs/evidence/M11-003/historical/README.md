# Historical M11-003 receipts

Everything in this directory was produced on 2026-10-09 for the working tree
measured before the Stack #200 follow-up fixes, at observed HEAD
`d96a333e4017059dc38f62ddda03a3536c200676`. It is retained byte-for-byte only to
preserve the original tool output.

It is **not** current validation. The source-bound acceptance in
`historical/verification.json` describes that earlier tree. This branch then
changed `src/http/websocket.cj`, `src/http/websocket_test.cj`,
`src/http/client.cj`, `src/http/facade_test.cj`,
`src/internal/connector/happy_eyeballs.cj`,
`src/internal/connector/happy_eyeballs_test.cj`, added
`src/http/upgrade_terminal_test.cj`, and extended `tools/tasks/M11-003.json`.

Nothing here may be cited as evidence for the current candidate. Regenerate the
canonical receipts at `docs/evidence/M11-003/` from the current sources on the
qualified Linux SDK environment and rebuild `verification.json` before this task
can leave BLOCKED.
