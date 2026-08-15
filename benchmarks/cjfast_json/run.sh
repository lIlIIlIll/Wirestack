#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
CJFAST_JSON_REF="${CJFAST_JSON_REF:-eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65}"
CJFAST_JSON_REPO="${CJFAST_JSON_REPO:-https://gitcode.com/Cangjie-TPC/cjfast_json.git}"
CJFAST_JSON_DIR="${CJFAST_JSON_DIR:-${1:-}}"
WORK_DIR="$(mktemp -d /tmp/fastjson-reflect-cjfast.XXXXXX)"
trap 'rm -rf -- "${WORK_DIR}"' EXIT

if [[ -n "${CJFAST_JSON_DIR}" ]]; then
    git -C "${CJFAST_JSON_DIR}" archive "${CJFAST_JSON_REF}" | tar -x -C "${WORK_DIR}"
else
    git clone --quiet "${CJFAST_JSON_REPO}" "${WORK_DIR}"
    git -C "${WORK_DIR}" checkout --quiet "${CJFAST_JSON_REF}"
fi

mkdir -p "${WORK_DIR}/src/bench"
cp "${ROOT_DIR}/benchmarks/cjfast_json/cjfast_comprehensive_bench.cj" "${WORK_DIR}/src/bench/"
cd "${WORK_DIR}"
exec cjpm bench --no-color --filter CjFastJsonComprehensiveBenchmarks
