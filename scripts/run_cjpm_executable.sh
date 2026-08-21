#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s PACKAGE_DIR\n' "$0" >&2
    exit 2
fi

package_dir=$1
if [[ ! -d "$package_dir" ]]; then
    printf 'error: package directory not found: %s\n' "$package_dir" >&2
    exit 2
fi

cd "$package_dir"
cjpm build

binary=target/release/bin/main
if [[ ! -x "$binary" ]]; then
    printf 'error: expected executable not found: %s/%s\n' "$package_dir" "$binary" >&2
    exit 2
fi

exec "$binary"
