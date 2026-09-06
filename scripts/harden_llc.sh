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
    # Warm runner VMs persist /opt/hostedtoolcache across jobs, and
    # setup-cangjie may then reuse a cached SDK whose wrapper was
    # installed by an older revision of this script. Keep the preserved
    # real binary but ALWAYS rewrite the wrapper to this revision.
    echo "harden_llc: real binary already preserved at $llc.yjson-real"
else
    mv "$llc" "$llc.yjson-real"
fi
cat > "$llc" <<'WRAPPER'
#!/usr/bin/env bash
dir="$(cd "$(dirname "$0")" && pwd)"
args=("$@")
attempt=1
while :; do
    "$dir/llc.yjson-real" "${args[@]}"
    status=$?
    if [[ "$status" -ne 139 ]]; then
        exit "$status"
    fi
    echo "llc attempt $attempt crashed with SIGSEGV" >&2
    if [[ "$attempt" -eq 3 ]]; then
        # The crash is deterministic on some GitHub runner CPU models, so
        # retries alone cannot recover. Fall back to -O1 lowering, which
        # avoids the faulty -O2 pass pipeline in the bundled libLLVM-15.
        downgraded=()
        for arg in "${args[@]}"; do
            if [[ "$arg" == "-O2" ]]; then
                downgraded+=(-O1)
            else
                downgraded+=("$arg")
            fi
        done
        args=("${downgraded[@]}")
        echo "llc: falling back to -O1 codegen for this host" >&2
    fi
    if [[ "$attempt" -ge 6 ]]; then
        exit 139
    fi
    attempt=$((attempt + 1))
done
WRAPPER
chmod +x "$llc"
echo "harden_llc: retry wrapper installed at $llc"
