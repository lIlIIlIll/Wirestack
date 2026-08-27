#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/yjson-coverage.XXXXXX")
trap 'rm -rf "$work"' EXIT

cd "$root"
python3 -c 'import shutil; shutil.rmtree("coverage", ignore_errors=True); shutil.rmtree("cov_output", ignore_errors=True)' \
    </dev/null
cp "$root/cjpm.toml" "$root/cjpm.lock" "$work/"
mkdir -p "$work/packages"
cp -R "$root/src" "$work/src"
cp -R "$root/packages/yjson_macros" "$work/packages/yjson_macros"
perl -0pi -e 's/compile-option = "-O2"/compile-option = "-O0"/' "$work/cjpm.toml"
grep -F 'compile-option = "-O0"' "$work/cjpm.toml" >/dev/null
mkdir -p "$root/coverage"

cd "$work"
cjpm clean
# Coverage instrumentation can make allocation-heavy compact-document cases
# exceed unittest's short default case timeout without changing their result.
cjpm test --coverage --no-progress --timeout-each=30s
cjcov --root . --source src --include src --output "$root/coverage/cjcov" \
    --branches --json --xml --html-details --keep
python3 "$root/scripts/cjcov_to_lcov.py" \
    --root . --gcov-root cov_output --output "$root/coverage/lcov.info" \
    --baseline "$root/coverage-baseline.toml"

printf 'yjson core coverage passed\n'
