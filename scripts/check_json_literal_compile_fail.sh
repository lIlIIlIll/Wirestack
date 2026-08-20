#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)

if output=$(cd "$repo/packages/json_literal_compile_fail" && cjpm build 2>&1); then
    printf '%s\n' "$output" >&2
    printf 'error: duplicate static JSON literal keys unexpectedly compiled\n' >&2
    exit 1
fi

case "$output" in
    *"duplicate static object key"*) ;;
    *)
        printf '%s\n' "$output" >&2
        printf 'error: compile failed without the expected duplicate-key diagnostic\n' >&2
        exit 1
        ;;
esac

printf 'json literal compile-fail check passed\n'
