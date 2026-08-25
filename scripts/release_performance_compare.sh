#!/usr/bin/env bash
set -euo pipefail

# SDK envsetup files may put an incompatible libpcre2 ahead of the host libc.
# Stop that environment from affecting source staging and ordinary host tools.
sdk_ld_library_path=${YJSON_PERF_SDK_LD_LIBRARY_PATH:-${LD_LIBRARY_PATH:-}}
unset LD_LIBRARY_PATH

repo=$(cd "$(dirname "$0")/.." && pwd)
result=${1:?usage: release_performance_compare.sh RESULT_DIR [CJFAST_WORK_DIR]}
cjfast_work=${2:-}
runs=${YJSON_PERF_RUNS:-11}
cpu=${YJSON_PERF_CPU:-8}
heap=${YJSON_PERF_HEAP:-128MB}
cv_limit=${YJSON_PERF_CV_LIMIT:-5}
owned_cjfast=0
source_stage=
runtime_view=

cleanup() {
    if [[ -n "$source_stage" ]]; then
        rm -rf -- "$source_stage"
    fi
    if [[ -n "$runtime_view" ]]; then
        rm -rf -- "$runtime_view"
    fi
    if [[ "$owned_cjfast" == "1" && -n "$cjfast_work" ]]; then
        rm -rf -- "$cjfast_work"
    fi
}
trap cleanup EXIT

mkdir -p "$result"
result=$(cd "$result" && pwd)
if [[ -n "$(find "$result" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "result directory is not empty: $result" >&2
    exit 2
fi

# Never benchmark directly from a developer checkout. The allowlisted release
# tree excludes target/, build-script-cache/, VCS state, and ignored artifacts.
source_stage=$(mktemp -d "${TMPDIR:-/tmp}/yjson-release-source.XXXXXX")
python3 "$repo/scripts/release_temp_tree.py" "$source_stage"
cache_path=$(find "$source_stage" -type d \
    \( -name target -o -name build-script-cache -o -name .git \) -print -quit)
if [[ -n "$cache_path" ]]; then
    echo "source-only staging contains forbidden generated state: $cache_path" >&2
    exit 2
fi

if [[ -z "$cjfast_work" ]]; then
    cjfast_work=$(mktemp -d "${TMPDIR:-/tmp}/yjson-release-cjfast.XXXXXX")
    owned_cjfast=1
fi

# Keep the SDK runtime libraries but let the host provide libpcre2 when the SDK
# bundle is newer than the host glibc. This view is isolated to benchmark tools
# and executables; it never mutates the SDK.
sanitized_paths=()
if [[ -n "$sdk_ld_library_path" ]]; then
    IFS=: read -r -a sdk_paths <<< "$sdk_ld_library_path"
    for sdk_path in "${sdk_paths[@]}"; do
        [[ -n "$sdk_path" ]] || continue
        if [[ -f "$sdk_path/libcangjie-runtime.so" &&
              "${YJSON_PERF_PRESERVE_SDK_PCRE2:-0}" != "1" ]]; then
            if [[ -z "$runtime_view" ]]; then
                runtime_view=$(mktemp -d "${TMPDIR:-/tmp}/yjson-runtime-view.XXXXXX")
            fi
            for library in "$sdk_path"/*; do
                name=${library##*/}
                case "$name" in
                    libpcre2*) ;;
                    *) ln -sf -- "$library" "$runtime_view/$name" ;;
                esac
            done
        else
            sanitized_paths+=("$sdk_path")
        fi
    done
fi
if [[ -n "$runtime_view" ]]; then
    sanitized_paths=("$runtime_view" "${sanitized_paths[@]}")
fi
if [[ "${#sanitized_paths[@]}" -gt 0 ]]; then
    printf -v sanitized_ld_library_path '%s:' "${sanitized_paths[@]}"
    export LD_LIBRARY_PATH=${sanitized_ld_library_path%:}
fi

preflight="$result/preflight"
mkdir -p "$preflight"
{
    printf 'source_stage_policy=release-files allowlist\n'
    printf 'sdk_ld_library_path=%s\n' "$sdk_ld_library_path"
    printf 'effective_ld_library_path=%s\n' "${LD_LIBRARY_PATH:-}"
    printf 'runtime_view=%s\n' "$runtime_view"
    printf 'excluded_sdk_pcre2=%s\n' \
        "$([[ -n "$runtime_view" ]] && printf true || printf false)"
    cjc -v
    cjpm --version
    /bin/mkdir --version | head -1
} > "$preflight/environment.txt" 2>&1

CJFAST_PREPARE_ONLY=1 CJFAST_REQUIRE_CLEAN_SOURCE=1 CJFAST_JSON_WORK_DIR="$cjfast_work" \
    bash "$source_stage/benchmarks/cjfast_json/run.sh" \
    > "$preflight/cjfast-prepare.log" 2>&1

export cjHeapSize="$heap"
export LC_ALL=C
(
    cd "$source_stage/packages/benchmarks"
    taskset -c "$cpu" cjpm bench --no-color \
        --filter 'ComprehensiveJsonCompareBenchmarks.yjsonStringDecodePrettyPerson*'
) > "$preflight/yjson.log" 2>&1 < /dev/null
(
    cd "$source_stage/packages/benchmarks"
    taskset -c "$cpu" cjpm bench --skip-build --no-color \
        --filter 'ComprehensiveJsonCompareBenchmarks.stdxStringDecodePrettyPerson*'
) > "$preflight/stdx-json.log" 2>&1 < /dev/null
(
    cd "$cjfast_work"
    taskset -c "$cpu" cjpm bench --no-color \
        --filter 'CjFastJsonComprehensiveBenchmarks.cjfastStringDecodePrettyPerson*'
) > "$preflight/cjfast-json.log" 2>&1 < /dev/null

if [[ "${YJSON_PERF_PREFLIGHT_ONLY:-0}" == "1" ]]; then
    (
        cd "$result"
        sha256sum preflight/environment.txt preflight/cjfast-prepare.log \
            preflight/yjson.log preflight/stdx-json.log preflight/cjfast-json.log \
            > checksums.txt
    )
    printf 'release performance preflight complete: %s\n' "$result"
    exit 0
fi

yjson_commit=${YJSON_RELEASE_COMMIT:-$(git -C "$repo" rev-parse HEAD)}
python3 "$source_stage/scripts/json_cjfast_perf_run.py" "$result/run" \
    --cjfast-work-dir "$cjfast_work" \
    --runs "$runs" --cpu "$cpu" --heap "$heap" \
    --yjson-commit "$yjson_commit"

python3 "$source_stage/scripts/json_cjfast_perf_summary.py" "$result/run" \
    --min-runs "$runs" --cv-limit "$cv_limit" \
    --json "$result/summary.json" \
    --csv "$result/summary.csv" \
    --markdown "$result/summary.md"

(
    cd "$result"
    sha256sum preflight/environment.txt preflight/cjfast-prepare.log \
        preflight/yjson.log preflight/stdx-json.log preflight/cjfast-json.log \
        run/metadata.json run/manifest.csv \
        summary.json summary.csv summary.md \
        > checksums.txt
)

printf 'release performance comparison complete: %s\n' "$result"
