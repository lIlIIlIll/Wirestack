#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
job=${1:-}
modules=$(mktemp -d "${TMPDIR:-/tmp}/yjson-ci-modules.XXXXXX")
trap 'rm -rf "$modules"' EXIT

require_cangjie() {
    command -v cjc >/dev/null || { echo 'cjc is required on the CI runner' >&2; exit 2; }
    command -v cjpm >/dev/null || { echo 'cjpm is required on the CI runner' >&2; exit 2; }
}

dependency_override_args() {
    if [[ -n "${YJSON_CI_DEPENDENCY_OVERRIDE:-}" ]]; then
        printf '%s\n' "--override-compile-option=${YJSON_CI_DEPENDENCY_OVERRIDE}"
    fi
}

run_with_dependency_override() {
    local project=$1
    shift
    local override=${YJSON_CI_DEPENDENCY_OVERRIDE:-}
    if [[ -z "$override" ]]; then
        (cd "$project" && "$@")
        return
    fi

    local manifest="$project/cjpm.toml"
    local backup
    backup=$(mktemp "${TMPDIR:-/tmp}/yjson-cjpm-manifest.XXXXXX")
    cp "$manifest" "$backup"
    python3 - "$manifest" "$override" <<'PY'
import pathlib
import sys

manifest = pathlib.Path(sys.argv[1])
override = sys.argv[2]
if override not in ("-O0", "-O1"):
    raise SystemExit(f"unsupported dependency override: {override}")
text = manifest.read_text(encoding="utf-8")
marker = 'override-compile-option = ""'
replacement = f'override-compile-option = "{override}"'
if text.count(marker) == 1:
    text = text.replace(marker, replacement)
elif marker not in text and text.count('compile-option = "-O2"') == 1:
    text = text.replace(
        'compile-option = "-O2"',
        f'compile-option = "-O2"\n{replacement}',
    )
else:
    raise SystemExit(f"unexpected cjpm manifest: {manifest}")
manifest.write_text(text, encoding="utf-8")
PY
    set +e
    (cd "$project" && "$@")
    local status=$?
    set -e
    cp "$backup" "$manifest"
    rm -f "$backup"
    return "$status"
}

stage_modules() {
    python3 "$repo/scripts/release_package_stage.py" "$modules" --development
}

case "$job" in
    stream-docs)
        python3 "$repo/scripts/test_stage_source_tree.py"
        evidence="$repo/benchmarks/results/stream-v1/2026-08-28"
        extracted="$modules/stream-evidence"
        peer_extracted="$modules/stream-peer-evidence"
        regenerated="$modules/stream-regenerated"
        (cd "$evidence" && sha256sum -c checksums.txt)
        python3 "$repo/scripts/generate_json_stream_workloads.py" \
            "$evidence/formal-cell-1" --check
        python3 "$repo/scripts/check_local_markdown_links.py" \
            "$repo/README.md" \
            "$repo/benchmarks/README.md" \
            "$evidence/README.md" \
            "$repo/docs/README.md" \
            "$repo/docs/streams.md" \
            "$repo/docs/performance.md" \
            "$repo/docs/performance/README.md" \
            "$repo/docs/performance/methodology.md" \
            "$repo/docs/performance/stream.md" \
            "$repo/docs/performance/stream-workloads.md" \
            "$repo/docs/performance/results/2026-08-28-stream-protocol-v1.md"
        mkdir -p "$extracted" "$peer_extracted" "$regenerated"
        tar -xzf "$evidence/formal-cell-1.tar.gz" -C "$extracted"
        tar -xzf "$evidence/peer-cell-1.tar.gz" -C "$peer_extracted"
        python3 "$repo/scripts/json_stream_protocol_summary.py" \
            "$extracted/formal-cell-1" --variant baseline \
            --json "$regenerated/baseline-summary.json" \
            --markdown "$regenerated/baseline-summary.md" >/dev/null
        python3 "$repo/scripts/json_stream_protocol_summary.py" \
            "$extracted/formal-cell-1" --variant candidate \
            --json "$regenerated/candidate-summary.json" \
            --markdown "$regenerated/candidate-summary.md" >/dev/null
        python3 "$repo/scripts/json_stream_protocol_compare.py" \
            "$regenerated/baseline-summary.json" "$regenerated/candidate-summary.json" \
            --json "$regenerated/compare.json" \
            --markdown "$regenerated/compare.md" >/dev/null
        python3 "$repo/scripts/json_stream_protocol_compare.py" \
            "$regenerated/baseline-summary.json" "$regenerated/candidate-summary.json" \
            --candidate-lifecycle unpooled \
            --json "$regenerated/compare-unpooled.json" \
            --markdown "$regenerated/compare-unpooled.md" >/dev/null
        for name in baseline-summary.json candidate-summary.json compare.json \
                compare-unpooled.json; do
            python3 "$repo/scripts/check_json_numeric_equivalence.py" \
                "$evidence/formal-cell-1/$name" "$regenerated/$name"
        done
        for name in baseline-summary.md candidate-summary.md compare.md compare-unpooled.md; do
            cmp "$regenerated/$name" "$evidence/formal-cell-1/$name"
        done
        python3 "$repo/scripts/json_stream_peer_summary.py" \
            "$peer_extracted/yjson-stream-peer-v1-20260828-formal-v10" \
            --json "$regenerated/peer-summary.json" \
            --markdown "$regenerated/peer-summary.md" >/dev/null
        python3 "$repo/scripts/check_json_numeric_equivalence.py" \
            "$evidence/peer-cell-1/peer-summary.json" "$regenerated/peer-summary.json"
        cmp "$regenerated/peer-summary.md" "$evidence/peer-cell-1/peer-summary.md"
        ;;
    api-inventory)
        python3 "$repo/scripts/check_api_inventory.py"
        ;;
    runtime-freeze)
        require_cangjie
        run_with_dependency_override "$repo/packages/runtime_freeze_contract" \
            "$repo/scripts/runtime_freeze_contract_checks.sh"
        ;;
    core)
        require_cangjie
        (cd "$repo" && cjpm test --no-color)
        ;;
    standards-conformance)
        require_cangjie
        mapfile -t override_args < <(dependency_override_args)
        python3 "$repo/scripts/run_standards_conformance.py" --quiet-failures \
            "${override_args[@]}"
        ;;
    schema-formats-conformance)
        require_cangjie
        mapfile -t override_args < <(dependency_override_args)
        python3 "$repo/scripts/run_standards_conformance.py" --quiet-failures \
            --include-schema-optional "${override_args[@]}"
        ;;
    performance-comparison)
        require_cangjie
        : "${YJSON_PERF_RESULT_DIR:?set YJSON_PERF_RESULT_DIR}"
        "$repo/scripts/release_performance_compare.sh" "$YJSON_PERF_RESULT_DIR" \
            "${YJSON_CJFAST_WORK_DIR:-}"
        ;;
    examples)
        require_cangjie
        run_with_dependency_override "$repo/packages/examples" \
            "$repo/scripts/run_cjpm_executable.sh" "$repo/packages/examples"
        ;;
    macro-consumer)
        require_cangjie
        run_with_dependency_override "$repo/packages/codec_integration" \
            "$repo/scripts/run_cjpm_executable.sh" "$repo/packages/codec_integration"
        run_with_dependency_override "$repo/packages/json_literal_integration" \
            "$repo/scripts/run_cjpm_executable.sh" "$repo/packages/json_literal_integration"
        run_with_dependency_override "$repo/packages/json_literal_compile_fail" \
            "$repo/scripts/check_json_literal_compile_fail.sh"
        stage_modules
        mapfile -t override_args < <(dependency_override_args)
        python3 "$repo/scripts/release_consumer_checks.py" \
            --modules-root "$modules" --only macro "${override_args[@]}"
        ;;
    algorithms-consumer)
        require_cangjie
        stage_modules
        mapfile -t override_args < <(dependency_override_args)
        python3 "$repo/scripts/release_consumer_checks.py" \
            --modules-root "$modules" --only algorithms --only schema-formats \
            "${override_args[@]}"
        ;;
    registry-rehearsal)
        require_cangjie
        rehearsal="$modules/registry-rehearsal"
        registry_args=()
        if [[ -n "${YJSON_CI_DEPENDENCY_OVERRIDE:-}" ]]; then
            registry_args+=(
                "--bundle-override-compile-option=${YJSON_CI_DEPENDENCY_OVERRIDE}"
                "--consumer-override-compile-option=${YJSON_CI_DEPENDENCY_OVERRIDE}")
        fi
        python3 "$repo/scripts/release_registry_rehearsal.py" "$rehearsal" \
            "${registry_args[@]}"
        ;;
    custom-native)
        require_cangjie
        run_with_dependency_override "$repo/packages/yjson_native" cjpm test --no-color
        stage_modules
        mapfile -t override_args < <(dependency_override_args)
        python3 "$repo/scripts/release_consumer_checks.py" \
            --modules-root "$modules" --only native "${override_args[@]}"
        if nm -g --defined-only "$repo/packages/yjson_native/target/native/libyjson_scanner.a" | \
                awk '{print $3}' | grep -E '^(yyjson_|unsafe_yyjson_)' >/dev/null; then
            echo 'custom native archive unexpectedly contains yyjson symbols' >&2
            exit 1
        fi
        ;;
    yyjson-native)
        require_cangjie
        run_with_dependency_override "$repo/packages/yjson_yyjson" cjpm test --no-color
        stage_modules
        mapfile -t override_args < <(dependency_override_args)
        python3 "$repo/scripts/release_consumer_checks.py" \
            --modules-root "$modules" --only yyjson "${override_args[@]}"
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
        echo 'usage: scripts/ci_job.sh {stream-docs|api-inventory|runtime-freeze|core|standards-conformance|schema-formats-conformance|performance-comparison|examples|macro-consumer|algorithms-consumer|registry-rehearsal|custom-native|yyjson-native|native-clang|native-gcc|sanitizer|fuzz-short|fuzz-extended|yyjson-colink}' >&2
        exit 2
        ;;
esac
