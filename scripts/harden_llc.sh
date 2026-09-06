#!/usr/bin/env bash
# Wrap the SDK llc so flaky SIGSEGV exits are retried instead of failing
# the gate. The nightly libLLVM-15 intermittently segfaults on
# GitHub-hosted runners while lowering identical, previously-successful
# IR (exit 139); a freshly spawned process normally succeeds, so bounded
# retries mask the toolchain bug without touching product code. The
# wrapper is idempotent and preserves the real binary as llc.yjson-real.
set -euo pipefail

cjc_path="$(command -v cjc)" || {
    echo "harden_llc: cjc not found on PATH" >&2
    exit 1
}
sdk_bin="$(cd "$(dirname "$cjc_path")/../third_party/llvm/bin" && pwd)"
llc="$sdk_bin/llc"

if [[ ! -f "$llc" ]]; then
    echo "harden_llc: llc not found at $llc" >&2
    exit 1
fi
if [[ -f "$llc.yjson-real" ]]; then
    echo "harden_llc: wrapper already installed at $llc"
    exit 0
fi

mv "$llc" "$llc.yjson-real"
cat > "$llc" <<'WRAPPER'
#!/usr/bin/env bash
dir="$(cd "$(dirname "$0")" && pwd)"
attempt=1
while :; do
    "$dir/llc.yjson-real" "$@"
    status=$?
    if [[ "$status" -ne 139 ]] || [[ "$attempt" -ge 6 ]]; then
        exit "$status"
    fi
    echo "llc attempt $attempt crashed with SIGSEGV; retrying" >&2
    attempt=$((attempt + 1))
done
WRAPPER
chmod +x "$llc"
echo "harden_llc: retry wrapper installed at $llc"
