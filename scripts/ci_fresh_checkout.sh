#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tree=$(mktemp -d "${TMPDIR:-/tmp}/yjson-ci-source.XXXXXX")
trap 'rm -rf "$tree"' EXIT

python3 "$repo/scripts/release_temp_tree.py" "$tree"
jobs=${YJSON_CI_JOBS:-"core examples macro-consumer custom-native yyjson-native native-clang native-gcc sanitizer fuzz-short"}
for job in $jobs; do
    printf '\n== fresh CI job: %s ==\n' "$job"
    "$tree/scripts/ci_job.sh" "$job"
done

printf '\nfresh-checkout CI simulation passed jobs=%s\n' "$jobs"
