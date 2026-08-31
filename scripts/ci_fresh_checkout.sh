#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tree=$(mktemp -d "${TMPDIR:-/tmp}/yjson-ci-source.XXXXXX")
registry_tree="${tree}.registry"
trap 'rm -rf "$tree" "$registry_tree"' EXIT

python3 "$repo/scripts/release_temp_tree.py" "$tree" --enforce-clean
jobs=${YJSON_CI_JOBS:-"api-inventory cjdoc-qualification api-docs runtime-freeze core standards-conformance schema-formats-conformance examples macro-consumer algorithms-consumer registry-rehearsal custom-native yyjson-native native-clang native-gcc sanitizer fuzz-short"}
for job in $jobs; do
    printf '\n== fresh CI job: %s ==\n' "$job"
    job_tree="$tree"
    if [[ "$job" == "registry-rehearsal" ]]; then
        python3 "$repo/scripts/release_temp_tree.py" \
            "$registry_tree" --enforce-clean
        job_tree="$registry_tree"
    fi
    "$job_tree/scripts/ci_job.sh" "$job"
done

printf '\nfresh-checkout CI simulation passed jobs=%s\n' "$jobs"
