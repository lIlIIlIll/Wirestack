# Raw evidence handling

Committed reports:

```text
linux-profile.json
tls-failure-cleanup.json
production-cleanup.json
```

SHA-256:

```text
0cf4528c203131d4c6926ce27f9dbbbf3f11ff10f21848169d5ecc2a4248b93d  linux-profile.json
fa4b773ade2ed3a8f654d7c3851f99b09df89e1c24ac991867c20098832bbbac  tls-failure-cleanup.json
ee0fbf5b2878989b9c22f01e04f9b4925c63fe3f0c3c35ddb8f2ddda5e7073a9  production-cleanup.json
```

The reports bind the execution to harness revision `4323da2` and retain exact
commands, exit/timeout state, process output, server counters, resource samples,
aggregates, source identity and deferred requirements.

`production-cleanup.json` binds the production-path closeout to revision
`e35365ae82775e639cf39c57e82c42f07e5f3b93`. It reuses the two reports above by
their exact SHA-256 values and does not start another 24-hour soak.

Reproduce with the commands documented in [`docs/gates/README.md`](../../../gates/README.md).
The TLS report must be generated first and passed unchanged to the full Linux
transport/soak command.
