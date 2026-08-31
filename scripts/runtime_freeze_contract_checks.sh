#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
package="$repo/packages/runtime_freeze_contract"

for scenario in pure-late generated-reader-late version-mismatch native-conflict activation-failure concurrent-race reentrant-use initialization-wait; do
    printf 'runtime freeze scenario: %s\n' "$scenario"
    output=$(cd "$package" && cjpm run -- "$scenario" 2>&1)
    printf '%s\n' "$output"
    grep -F "runtime freeze contract passed: $scenario" <<<"$output" >/dev/null
done

printf 'runtime freeze contract checks passed\n'
