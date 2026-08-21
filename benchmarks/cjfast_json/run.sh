#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
CJFAST_JSON_REF="${CJFAST_JSON_REF:-eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65}"
CJFAST_JSON_REPO="${CJFAST_JSON_REPO:-https://gitcode.com/Cangjie-TPC/cjfast_json.git}"
CJFAST_JSON_DIR="${CJFAST_JSON_DIR:-${1:-}}"
CJFAST_JSON_WORK_DIR="${CJFAST_JSON_WORK_DIR:-}"
CJFAST_SKIP_BUILD="${CJFAST_SKIP_BUILD:-0}"
CJFAST_STDX_FFI_DIR="${CJFAST_STDX_FFI_DIR:-${CANGJIE_STDX_PATH:-}}"
CJFAST_STDX_FFI_DIR="${CJFAST_STDX_FFI_DIR/\/dynamic\/stdx/\/static\/stdx}"
CJFAST_SDK_LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
unset LD_LIBRARY_PATH
if [[ -n "${CJFAST_JSON_WORK_DIR}" ]]; then
    WORK_DIR="${CJFAST_JSON_WORK_DIR}"
    mkdir -p "${WORK_DIR}"
else
    WORK_DIR="$(mktemp -d /tmp/fastjson-reflect-cjfast.XXXXXX)"
    trap 'env -u LD_LIBRARY_PATH rm -rf -- "${WORK_DIR}"' EXIT
fi

if [[ ! -f "${WORK_DIR}/cjpm.toml" ]]; then
    if [[ -n "${CJFAST_JSON_DIR}" ]]; then
        env -u LD_LIBRARY_PATH git -C "${CJFAST_JSON_DIR}" archive "${CJFAST_JSON_REF}" | tar -x -C "${WORK_DIR}"
    else
        env -u LD_LIBRARY_PATH git clone --quiet "${CJFAST_JSON_REPO}" "${WORK_DIR}"
        env -u LD_LIBRARY_PATH git -C "${WORK_DIR}" checkout --quiet "${CJFAST_JSON_REF}"
    fi
fi

# The pinned project imports stdx packages but leaves its dependency table empty.
# Patch only the disposable benchmark checkout so cjpm 1.1 can resolve them.
if ! grep -Eq '^[[:space:]]*"?stdx"?[[:space:]]*=' "${WORK_DIR}/cjpm.toml"; then
    sed -i '/^\[dependencies\]$/a\  "stdx" = "0.0.3"' "${WORK_DIR}/cjpm.toml"
fi
if [[ ! -f "${CJFAST_STDX_FFI_DIR}/libstdx.encoding.jsonFFI.a" ||
      ! -f "${CJFAST_STDX_FFI_DIR}/libstdx.encoding.json.streamFFI.a" ]]; then
    echo "error: stdx JSON FFI libraries not found under ${CJFAST_STDX_FFI_DIR}" >&2
    exit 1
fi
sed -i "s|^  link-option = \"\"$|  link-option = \"-L ${CJFAST_STDX_FFI_DIR} -lstdx.encoding.jsonFFI -lstdx.encoding.json.streamFFI\"|" \
    "${WORK_DIR}/cjpm.toml"

mkdir -p "${WORK_DIR}/src/bench"
cp "${ROOT_DIR}/benchmarks/cjfast_json/cjfast_comprehensive_bench.cj" "${WORK_DIR}/src/bench/"
cd "${WORK_DIR}"
export LD_LIBRARY_PATH="${CJFAST_SDK_LD_LIBRARY_PATH}"
if [[ "${CJFAST_SKIP_BUILD}" == "1" ]]; then
    cjpm bench --skip-build --no-color --filter CjFastJsonComprehensiveBenchmarks
else
    cjpm bench --no-color --filter CjFastJsonComprehensiveBenchmarks
fi
