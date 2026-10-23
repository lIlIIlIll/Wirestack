# Historical M11-001 receipts

Everything in this directory was produced on 2026-10-08 for the working tree
measured before the post-review SSE fixes, at observed HEAD
`1f433d5cd4daf634672910cf2ff166069fcd072c`. It is retained byte-for-byte only
to preserve the original tool output.

It is **not** current validation. Two review rounds changed production SSE
sources after these receipts were written (`src/sse/decoder.cj`,
`src/sse/session.cj`), and the review of Stack #200 then changed the decoder
cursor semantics, the writer's completed-EOF precedence and the task inventory.
`verification-2026-10-08.json` therefore still records
`production_current_matches_profile_and_installed: false`; the native,
installed-consumer, one-hour streaming, fuzz, API-documentation and task-gate
receipts under this directory all describe those earlier inputs.

Nothing here may be cited as evidence for the current candidate. Regenerate the
canonical receipts at `docs/evidence/M11-001/` from the current sources on the
qualified Linux SDK environment and rebuild `verification.json` before this task
can leave BLOCKED.
