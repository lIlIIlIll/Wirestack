#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
release_tmp=$(mktemp -d "${TMPDIR:-/tmp}/yjson-release-checks.XXXXXX")
trap 'rm -rf "$release_tmp"' EXIT

require_consistent_sdk() {
    local cjc_path sdk_root variable value entry resolved found
    local -a entries
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
    found=false
    if [[ -n "$value" ]]; then
        IFS=: read -r -a entries <<< "$value"
        for entry in "${entries[@]}"; do
            [[ -n "$entry" ]] || continue
            resolved=$(readlink -f "$entry" 2>/dev/null || true)
            if [[ "$resolved" == "$sdk_root"/* ]]; then
                found=true
                break
            fi
        done
    fi
    if [[ -n "$value" && "$found" != true ]]; then
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
run cjdoc-qualification-tests python3 "$repo/scripts/test_check_cjdoc_qualification.py"
printf '\n== cjdoc-qualification ==\n'
cjdoc_binary=$(python3 "$repo/scripts/prepare_cjdoc.py")
python3 "$repo/scripts/check_cjdoc_qualification.py" --binary "$cjdoc_binary"
run api-docs-tests python3 "$repo/scripts/test_generate_api_docs.py"
run api-docs python3 "$repo/scripts/generate_api_docs.py" \
    --cjdoc "$cjdoc_binary" --output "$release_tmp/api-docs"
run runtime-freeze "$repo/scripts/runtime_freeze_contract_checks.sh"
run core bash -c 'cd "$1" && cjpm test --no-color' _ "$repo"
run examples "$repo/scripts/run_cjpm_executable.sh" "$repo/packages/examples"
run macro-consumer "$repo/scripts/run_cjpm_executable.sh" "$repo/packages/codec_integration"
run custom-native-primitives bash -c 'cd "$1/packages/yjson_native_primitives" && cjpm test --no-color' _ "$repo"
run custom-native-accel bash -c 'cd "$1/packages/yjson_native_accel" && cjpm test --no-color' _ "$repo"
run custom-native bash -c 'cd "$1/packages/yjson_native" && cjpm test --no-color' _ "$repo"
run yyjson-native bash -c 'cd "$1/packages/yjson_yyjson" && cjpm test --no-color' _ "$repo"
run external-consumers python3 "$repo/scripts/release_consumer_checks.py"

printf '\nCangjie release checks passed\n'
