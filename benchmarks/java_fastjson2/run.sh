#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FASTJSON2_JAR="${FASTJSON2_JAR:-<home>/share/commandline-tools-6.0.2/sdk/default/openharmony/js/build-tools/binary-tools/fastjson2-2.0.52.jar}"
CLASS_DIR="${SCRIPT_DIR}/build/classes"

if [[ ! -f "${FASTJSON2_JAR}" ]]; then
    echo "fastjson2 jar not found: ${FASTJSON2_JAR}" >&2
    exit 1
fi

mkdir -p "${CLASS_DIR}"
javac -encoding UTF-8 -cp "${FASTJSON2_JAR}" -d "${CLASS_DIR}" "${SCRIPT_DIR}/Fastjson2Bench.java"
java -cp "${CLASS_DIR}:${FASTJSON2_JAR}" Fastjson2Bench "$@"
