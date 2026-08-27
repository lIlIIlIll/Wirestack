#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
package="$repo/packages/runtime_freeze_contract"

for scenario in pure-late version-mismatch native-conflict activation-failure concurrent-race; do
    printf 'runtime freeze scenario: %s\n' "$scenario"
    (cd "$package" && cjpm run -- "$scenario")
done

printf 'runtime freeze contract checks passed\n'
