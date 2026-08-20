#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)

require_consistent_sdk() {
    local cjc_path sdk_root variable value
    cjc_path=$(readlink -f "$(command -v cjc)")
    sdk_root=$(dirname "$(dirname "$cjc_path")")

    for variable in CANGJIE_HOME CANGJIE_SDK_ROOT; do
        value=${!variable:-}
        if [[ -n "$value" && "$(readlink -f "$value")" != "$sdk_root" ]]; then
            printf 'error: %s=%s does not match cjc SDK root %s\n' \
                "$variable" "$value" "$sdk_root" >&2
            printf 'activate one Cangjie SDK consistently before running release checks\n' >&2
            exit 2
        fi
    done

    value=${CJ_SDK_LIBPATH:-}
    if [[ -n "$value" && ":$value:" != *":$sdk_root/"* ]]; then
        printf 'error: CJ_SDK_LIBPATH does not reference cjc SDK root %s\n' \
            "$sdk_root" >&2
        printf 'activate one Cangjie SDK consistently before running release checks\n' >&2
        exit 2
    fi
}

run() {
    name=$1
    shift
    printf '\n== %s ==\n' "$name"
    "$@"
}

require_consistent_sdk

run api-inventory python3 "$repo/scripts/check_api_inventory.py"
run core bash -c 'cd "$1" && cjpm test --no-color' _ "$repo"
run examples bash -c 'cd "$1/packages/examples" && cjpm run' _ "$repo"
run macro-consumer bash -c 'cd "$1/packages/codec_integration" && cjpm run' _ "$repo"
run json-literal-consumer bash -c 'cd "$1/packages/json_literal_integration" && cjpm run' _ "$repo"
run json-literal-compile-fail "$repo/scripts/check_json_literal_compile_fail.sh"
run custom-native bash -c 'cd "$1/packages/yjson_native" && cjpm test --no-color' _ "$repo"
run yyjson-native bash -c 'cd "$1/packages/yjson_yyjson" && cjpm test --no-color' _ "$repo"
run external-consumers python3 "$repo/scripts/release_consumer_checks.py"

printf '\nCangjie release checks passed\n'
