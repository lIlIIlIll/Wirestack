# Task Evidence

Each task that reaches COMPLETE must leave reproducible evidence under:

```text
docs/evidence/<TASK-ID>/
```

Typical contents:

- `README.md`: scope, environment, commands, acceptance matrix and conclusion;
- raw or summarized test output when stable and reasonably sized;
- benchmark metadata and baseline comparison;
- fuzz seeds/corpus references;
- platform device/VM identifiers without secrets;
- links to upstream issues/PRs when a gate requires upstream changes.

Do not commit credentials, private keys, session secrets, traffic secrets,
Authorization/Cookie values, complete certificate DER dumps, or proprietary
device identifiers.

Large transient artifacts should live in CI artifacts or an approved external
store; the evidence README should link them by immutable run/artifact ID.
