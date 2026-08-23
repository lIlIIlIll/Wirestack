# Linux x86_64 supplied-SDK smoke

## Result

`PASS` for the SDK/package smoke scope.

## Environment

```text
cjc 1.1.0-alpha.20260817040003 (cjnative)
target: x86_64-unknown-linux-gnu
cjpm 1.1.3
```

The SDK archive was extracted outside the repository and its environment was loaded for the verification process. The archive, extracted SDK, standard library binaries, and runtime binaries are not committed to Wirestack.

## Commands executed against the M0-004 task tree

```text
python3 -m unittest discover -s tools/gates/tests -p 'test_gate_runner.py' -v
python3 -m unittest discover -s tools/tests -p 'test_architecture_guard.py' -v
python3 tools/architecture_guard.py --root . --format text
cjpm check
cjpm build
python3 tools/gates/gate_runner.py \
  --manifest tools/gates/manifests/sdk-smoke.json \
  --repo-root . \
  --artifact-dir build/gates/sdk-smoke-artifacts \
  --output build/gates/sdk-smoke.json
```

The generated JSON reported `SDK-SMOKE: PASS`; its final compiled program emitted `WIRESTACK_SDK_SMOKE_OK`.

## Evidence boundary

This proves only that the supplied Linux x86_64 SDK can check/build the current Wirestack skeleton and compile/run a minimal Cangjie program. It is not evidence for raw TCP semantics, GATE-NET-01 through GATE-NET-07, TLS, HTTP, performance, or any other target platform.
