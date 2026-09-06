#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
package="$repo/packages/runtime_freeze_contract"

for scenario in pure-late generated-reader-late version-mismatch native-conflict activation-failure concurrent-race reentrant-use initialization-wait; do
    printf 'runtime freeze scenario: %s\n' "$scenario"
    # A failed `cjpm run` used to abort under set -e before its output was
    # printed, hiding the cause. Retry flaky runner toolchain crashes
    # (llc SIGSEGV) while still surfacing the captured output.
    output=""
    status=0
    for attempt in 1 2 3; do
        output=$(cd "$package" && cjpm run -- "$scenario" 2>&1) || status=$?
        if [[ "$status" -eq 0 ]]; then
            break
        fi
        printf '%s\n' "$output"
        echo "runtime freeze: attempt $attempt failed for $scenario" >&2
    done
    printf '%s\n' "$output"
    if [[ "$status" -ne 0 ]]; then
        exit "$status"
    fi
    grep -F "runtime freeze contract passed: $scenario" <<<"$output" >/dev/null
done

printf 'runtime freeze contract checks passed\n'
