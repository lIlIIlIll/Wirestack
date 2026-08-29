# Reproduce the review package

Use Linux x86_64 glibc with the repository's configured Cangjie toolchain. Do
not build the SDK and do not run long-duration profiles.

From the repository root, run:

```sh
python3 tools/repository/repository_tooling.py --root . validate-plan \
  docs/evidence/M7-028/test-plan.md --json
python3 -m unittest tools.tests.test_m7_028_security_review_package -v
scripts/check-m7-028-security-review --json
scripts/check-task M7-028 --json
scripts/verify-evidence M7-028
```

The package gate checks exact paths, SHA-256 digests, evidence states, required
topics, the pre-1.0 non-compatibility policy, sensitive-data exclusions, and
atomic report output. A missing file, changed digest, unknown schema field,
path escape, false PASS, or sensitive value returns a nonzero exit status.

