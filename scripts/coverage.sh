#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/yjson-coverage.XXXXXX")
trap 'rm -rf "$work"' EXIT

cd "$root"
python3 scripts/test_cjcov_to_lcov.py
python3 -c 'import shutil; shutil.rmtree("coverage", ignore_errors=True); shutil.rmtree("cov_output", ignore_errors=True)' \
    </dev/null
cp "$root/cjpm.toml" "$root/cjpm.lock" "$work/"
mkdir -p "$work/packages"
cp -R "$root/src" "$work/src"
cp -R "$root/native" "$work/native"
mkdir -p "$work/scripts"
cp "$root/scripts/build_native_scanner.py" "$work/scripts/build_native_scanner.py"
cp -R "$root/packages/yjson_macros" "$work/packages/yjson_macros"
cp -R "$root/packages/runtime_freeze_contract" "$work/packages/runtime_freeze_contract"
cp -R "$root/packages/yjson_backends" "$work/packages/yjson_backends"
cp -R "$root/packages/yjson_native_primitives" "$work/packages/yjson_native_primitives"
cp -R "$root/packages/yjson_native" "$work/packages/yjson_native"
cp -R "$root/packages/yjson_native_accel" "$work/packages/yjson_native_accel"
python3 -c 'import shutil; shutil.rmtree("'"$work"'/packages/runtime_freeze_contract/target", ignore_errors=True); shutil.rmtree("'"$work"'/packages/runtime_freeze_contract/cov_output", ignore_errors=True)' \
    </dev/null
python3 -c 'import shutil; [shutil.rmtree("'"$work"'/packages/" + name + "/" + child, ignore_errors=True) for name in ("yjson_backends", "yjson_native_primitives", "yjson_native", "yjson_native_accel") for child in ("target", "cov_output", "build-script-cache")]' \
    </dev/null
perl -0pi -e 's/compile-option = "-O2"/compile-option = "-O0"/' "$work/cjpm.toml"
perl -0pi -e 's/compile-option = "-O2"/compile-option = "-O0"/' \
    "$work/packages/runtime_freeze_contract/cjpm.toml" \
    "$work/packages/yjson_backends/cjpm.toml" \
    "$work/packages/yjson_native_primitives/cjpm.toml" \
    "$work/packages/yjson_native/cjpm.toml" \
    "$work/packages/yjson_native_accel/cjpm.toml"
grep -F 'compile-option = "-O0"' "$work/cjpm.toml" >/dev/null
grep -F 'compile-option = "-O0"' "$work/packages/runtime_freeze_contract/cjpm.toml" >/dev/null
grep -F 'compile-option = "-O0"' "$work/packages/yjson_native_accel/cjpm.toml" >/dev/null
mkdir -p "$root/coverage"

cd "$work"
cjpm clean
# Coverage instrumentation can make allocation-heavy compact-document cases
# exceed unittest's short default case timeout without changing their result.
cjpm test --coverage --no-progress --timeout-each=30s
cjcov --root . --source src --include src --output "$root/coverage/cjcov" \
    --branches --json --xml --html-details --keep

runtime_package="$work/packages/runtime_freeze_contract"
cd "$runtime_package"
cjpm build --coverage
mkdir -p "$work/runtime-gcov" "$work/runtime-cjcov"
for scenario in pure-late generated-reader-late version-mismatch native-conflict activation-failure concurrent-race reentrant-use initialization-wait; do
    # Cangjie's gcda writer cannot reliably merge repeated process runs into
    # the same file. Collect each contract scenario independently, then merge
    # the resulting textual gcov records in cjcov_to_lcov.py.
    rm -f "$runtime_package"/*.gcda "$runtime_package"/*.gcov
    ./target/release/bin/main "$scenario"
    scenario_gcov="$work/runtime-gcov/$scenario"
    mkdir -p "$scenario_gcov"
    cjcov --root "$work" --source "$work/src" --include "$work/src" \
        --output "$work/runtime-cjcov/$scenario" --branches --json --keep
    cp "$runtime_package"/*.gcov "$scenario_gcov/"
done

native_package="$work/packages/yjson_native_accel"
cd "$native_package"
cjpm clean
cjpm test --coverage --no-progress --timeout-each=30s
cp -f 0-yjson.gcda cov_output/yjson_native_accel/0-yjson.gcda
cjcov --root "$work" --source "$work/src" --include "$work/src" \
    --output "$work/native-cjcov" --branches --json --keep

python3 "$root/scripts/cjcov_to_lcov.py" \
    --root "$root" \
    --gcov-root "$work/cov_output" \
    --gcov-root "$work/runtime-gcov" \
    --gcov-root "$native_package/cov_output" \
    --output "$root/coverage/lcov.info" \
    --baseline "$root/coverage-baseline.toml"

printf 'yjson core coverage passed\n'
