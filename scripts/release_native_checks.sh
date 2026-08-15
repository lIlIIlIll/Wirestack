#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cc=${CC:-cc}
cases=${YJSON_FUZZ_CASES:-5000}
mode=${YJSON_NATIVE_CHECK_MODE:-all}
work=$(mktemp -d "${TMPDIR:-/tmp}/yjson-native-release.XXXXXX")
trap 'rm -rf "$work"' EXIT

own_flags=(-std=c11 -O2 -Wall -Wextra -Werror -I "$repo/native")
vendor_flags=(-std=c11 -O2 -Wall -Wextra -fvisibility=hidden \
    '-Dyyjson_api=__attribute__((visibility("hidden")))' \
    -I "$repo/native/vendor/yyjson")

if [[ "$mode" == all || "$mode" == targeted ]]; then
    "$cc" "${own_flags[@]}" "$repo/native/yjson_scanner.c" \
        "$repo/native/test_yjson_scanner.c" -o "$work/scanner"
    "$cc" "${own_flags[@]}" -DYJ_TESTING "$repo/native/yjson_compact.c" \
        "$repo/native/test_yjson_compact.c" -o "$work/compact"
    "$cc" "${vendor_flags[@]}" -c "$repo/native/vendor/yyjson/yyjson.c" \
        -o "$work/yyjson.o"
    "$cc" "${own_flags[@]}" -DYJ_TESTING -c "$repo/native/yjson_compact.c" \
        -o "$work/compact-test.o"
    "$cc" "${own_flags[@]}" -DYJ_TESTING -c "$repo/native/yjson_yyjson.c" \
        -o "$work/adapter-test.o"
    "$cc" "${own_flags[@]}" -DYJ_TESTING -c "$repo/native/test_yjson_yyjson.c" \
        -o "$work/test-yyjson.o"
    "$cc" "$work/compact-test.o" "$work/adapter-test.o" "$work/yyjson.o" \
        "$work/test-yyjson.o" -o "$work/yyjson"

    "$work/scanner"
    "$work/compact"
    "$work/yyjson"
fi

san=(-std=c11 -O1 -g -DYJ_TESTING -fsanitize=address,undefined \
    -fno-omit-frame-pointer -I "$repo/native")
if [[ "$mode" == all || "$mode" == sanitizer ]]; then
    "$cc" "${san[@]}" "$repo/native/yjson_scanner.c" \
        "$repo/native/test_yjson_scanner.c" -o "$work/scanner-sanitized"
    "$cc" "${san[@]}" "$repo/native/yjson_compact.c" \
        "$repo/native/test_yjson_compact.c" -o "$work/compact-sanitized"
    "$cc" "${san[@]}" "$repo/native/yjson_compact.c" \
        "$repo/native/yjson_yyjson.c" "$repo/native/vendor/yyjson/yyjson.c" \
        "$repo/native/test_yjson_yyjson.c" -o "$work/yyjson-sanitized"
    ASAN_OPTIONS=detect_leaks=1 "$work/scanner-sanitized"
    ASAN_OPTIONS=detect_leaks=1 "$work/compact-sanitized"
    ASAN_OPTIONS=detect_leaks=1 "$work/yyjson-sanitized"
fi

if [[ "$mode" == all || "$mode" == fuzz ]]; then
    "$cc" "${san[@]}" -DYJ_FUZZ_STANDALONE \
        "$repo/native/yjson_compact.c" "$repo/native/yjson_yyjson.c" \
        "$repo/native/vendor/yyjson/yyjson.c" \
        "$repo/native/fuzz_yjson_semantics.c" -o "$work/fuzz"
    ASAN_OPTIONS=detect_leaks=1 "$work/fuzz" "$cases"
fi

printf 'native release checks passed compiler=%s mode=%s fuzz_cases=%s\n' \
    "$cc" "$mode" "$cases"
