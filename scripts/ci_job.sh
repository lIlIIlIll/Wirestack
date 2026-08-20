#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
job=${1:-}
cache=$(mktemp -d "${TMPDIR:-/tmp}/yjson-ci-cache.XXXXXX")
modules=$(mktemp -d "${TMPDIR:-/tmp}/yjson-ci-modules.XXXXXX")
trap 'rm -rf "$cache" "$modules"' EXIT
export CJPM_CONFIG="$cache/cjpm"

require_cangjie() {
    command -v cjc >/dev/null || { echo 'cjc is required on the CI runner' >&2; exit 2; }
    command -v cjpm >/dev/null || { echo 'cjpm is required on the CI runner' >&2; exit 2; }
}

stage_modules() {
    python3 "$repo/scripts/release_package_stage.py" "$modules" --development
}

case "$job" in
    api-inventory)
        python3 "$repo/scripts/check_api_inventory.py"
        ;;
    core)
        require_cangjie
        (cd "$repo" && cjpm test --no-color)
        ;;
    examples)
        require_cangjie
        (cd "$repo/packages/examples" && cjpm run)
        ;;
    macro-consumer)
        require_cangjie
        stage_modules
        python3 "$repo/scripts/release_consumer_checks.py" \
            --modules-root "$modules" --only macro
        ;;
    custom-native)
        require_cangjie
        (cd "$repo/packages/yjson_native" && cjpm test --no-color)
        stage_modules
        python3 "$repo/scripts/release_consumer_checks.py" \
            --modules-root "$modules" --only native
        if nm -g --defined-only "$repo/packages/yjson_native/target/native/libyjson_scanner.a" | \
                awk '{print $3}' | grep -E '^(yyjson_|unsafe_yyjson_)' >/dev/null; then
            echo 'custom native archive unexpectedly contains yyjson symbols' >&2
            exit 1
        fi
        ;;
    yyjson-native)
        require_cangjie
        (cd "$repo/packages/yjson_yyjson" && cjpm test --no-color)
        stage_modules
        python3 "$repo/scripts/release_consumer_checks.py" \
            --modules-root "$modules" --only yyjson
        ;;
    native-clang)
        CC=${CC:-clang} YJSON_NATIVE_CHECK_MODE=targeted \
            "$repo/scripts/release_native_checks.sh"
        ;;
    native-gcc)
        CC=${CC:-gcc} YJSON_NATIVE_CHECK_MODE=targeted \
            "$repo/scripts/release_native_checks.sh"
        ;;
    sanitizer)
        CC=${CC:-clang} YJSON_NATIVE_CHECK_MODE=sanitizer \
            "$repo/scripts/release_native_checks.sh"
        ;;
    fuzz-short)
        CC=${CC:-clang} YJSON_NATIVE_CHECK_MODE=fuzz YJSON_FUZZ_CASES=5000 \
            "$repo/scripts/release_native_checks.sh"
        ;;
    fuzz-extended)
        CC=${CC:-clang} YJSON_NATIVE_CHECK_MODE=fuzz YJSON_FUZZ_CASES=50000 \
            "$repo/scripts/release_native_checks.sh"
        ;;
    yyjson-colink)
        "$repo/scripts/release_yyjson_colink_check.sh"
        ;;
    *)
        echo 'usage: scripts/ci_job.sh {api-inventory|core|examples|macro-consumer|custom-native|yyjson-native|native-clang|native-gcc|sanitizer|fuzz-short|fuzz-extended|yyjson-colink}' >&2
        exit 2
        ;;
esac
