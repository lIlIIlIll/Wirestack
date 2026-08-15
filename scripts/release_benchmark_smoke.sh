#!/usr/bin/env bash
set -euo pipefail

repo=${1:?usage: release_benchmark_smoke.sh REPO RESULT_DIR}
result=${2:?usage: release_benchmark_smoke.sh REPO RESULT_DIR}
runner=${YJSON_PERF_RUNNER:-$repo/packages/perf_runner/target/release/bin/main}
runtime=${CANGJIE_RUNTIME_LIB:?set CANGJIE_RUNTIME_LIB to the SDK runtime library directory}
corpus=${YJSON_PERF_CORPUS:-$repo/target/perf-corpus}
mkdir -p "$result"

taskset -c 8 sh -c 'grep Cpus_allowed_list /proc/self/status' > "$result/affinity.log"

run_case() {
    local name=$1 file=$2 representation=$3 iterations=$4 warmup=$5
    taskset -c 8 env LD_LIBRARY_PATH="$runtime" cjHeapSize=128MB "$runner" \
        --corpus-file "$file" --corpus-name "$name" --corpus-input bytes \
        --corpus-representation "$representation" --samples 7 \
        --iterations "$iterations" --warmup "$warmup" \
        > "$result/$name-$representation.log" 2>&1
}

run_case flat64 "$corpus/generated/scalability/flat-object-64m.json" yyjson-direct-dispatch-document 1 1
run_case objectarray64 "$corpus/generated/scalability/object-array-64m.json" yyjson-direct-dispatch-document 1 1
run_case numeric64 "$corpus/generated/scalability/integer-array-64m.json" yyjson-direct-dispatch-document 1 1
run_case canada "$corpus/real/canada.json" yyjson-direct-dispatch-document 8 2
run_case twitter "$corpus/real/twitter.json" yyjson-direct-dispatch-document 20 5
run_case citm "$corpus/real/citm_catalog.json" yyjson-direct-dispatch-document 12 3
run_case canada-custom "$corpus/real/canada.json" native-compact-document 8 2
run_case canada-pure "$corpus/real/canada.json" compact-document 8 2

printf 'release benchmark smoke complete\n'
