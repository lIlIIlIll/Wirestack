# SDK baseline evidence

The supplied SDK archive was extracted outside the repository and used to validate the M0-002 package skeleton.

Observed toolchain:

```text
cjc 1.1.0-alpha.20260817040003 (cjnative)
target: x86_64-unknown-linux-gnu
cjpm 1.1.3
```

Verified M0-002 commands:

```text
cjpm check
cjpm build
./scripts/check
```

All three completed successfully against the frozen package layout. This evidence establishes only the Linux x86_64 build baseline; it is not network behavior or cross-platform support evidence.
