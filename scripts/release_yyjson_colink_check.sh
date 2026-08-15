#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cc=${CC:-cc}
second_root=${YJSON_SECOND_YYJSON_ROOT:-}
if [[ -z "$second_root" || ! -f "$second_root/src/yyjson.c" ]]; then
    printf 'error: set YJSON_SECOND_YYJSON_ROOT to unpacked yyjson 0.11.1\n' >&2
    exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/yjson-yyjson-colink.XXXXXX")
trap 'rm -rf "$work"' EXIT
common=(-std=c11 -O2 -fPIC -Wall -Wextra -Werror)

"$cc" "${common[@]}" -DYJ_TESTING -I "$repo/native" \
    -I "$repo/native/vendor/yyjson" -c "$repo/native/yjson_compact.c" \
    -o "$work/compact.o"
"$cc" "${common[@]}" -DYJ_TESTING -I "$repo/native" \
    -I "$repo/native/vendor/yyjson" -c "$repo/native/yjson_yyjson.c" \
    -o "$work/adapter.o"
"$cc" "${common[@]}" -I "$repo/native/vendor/yyjson" \
    -c "$repo/native/vendor/yyjson/yyjson.c" -o "$work/yyjson-visible.o"
"$cc" "${common[@]}" -fvisibility=hidden \
    '-Dyyjson_api=__attribute__((visibility("hidden")))' \
    -I "$repo/native/vendor/yyjson" \
    -c "$repo/native/vendor/yyjson/yyjson.c" -o "$work/yyjson-hidden.o"
"$cc" -shared "$work/compact.o" "$work/adapter.o" "$work/yyjson-visible.o" \
    -o "$work/libyjson-visible.so"
"$cc" -shared "$work/compact.o" "$work/adapter.o" "$work/yyjson-hidden.o" \
    -o "$work/libyjson-isolated.so"

"$cc" "${common[@]}" -I "$second_root/src" -c "$second_root/src/yyjson.c" \
    -o "$work/yyjson-second.o"
"$cc" -shared "$work/yyjson-second.o" -o "$work/libyyjson-second.so"
"$cc" "${common[@]}" -DYJ_TESTING -I "$repo/native" \
    -I "$repo/native/vendor/yyjson" -c "$repo/native/test_yyjson_colink.c" \
    -o "$work/test.o"

link_test() {
    local output=$1
    shift
    "$cc" "$work/test.o" -L "$work" "$@" \
        -Wl,-rpath,"$work" -o "$work/$output"
}

link_test visible-yjson-first -lyjson-visible -lyyjson-second
link_test visible-consumer-first -lyyjson-second -lyjson-visible
link_test isolated-yjson-first -lyjson-isolated -lyyjson-second
link_test isolated-consumer-first -lyyjson-second -lyjson-isolated

"$work/visible-yjson-first" 0x000c00 0x000c00
"$work/visible-consumer-first" 0x000b01 0x000b01
"$work/isolated-yjson-first" 0x000c00 0x000b01
"$work/isolated-consumer-first" 0x000c00 0x000b01

LD_DEBUG=bindings "$work/visible-consumer-first" 0x000b01 0x000b01 \
    2>"$work/visible-bindings.log" >/dev/null
if ! grep -E 'libyjson-visible.*libyyjson-second.*yyjson_(read|version)' \
        "$work/visible-bindings.log" >/dev/null; then
    printf 'error: baseline interposition was not observed in loader bindings\n' >&2
    grep -E 'yyjson_(read_opts|version)' "$work/visible-bindings.log" >&2 || true
    exit 1
fi
if nm -D --defined-only "$work/libyjson-isolated.so" | \
        awk '{print $3}' | grep -E '^(yyjson_|unsafe_yyjson_)' >/dev/null; then
    printf 'error: isolated backend still exports vendored yyjson symbols\n' >&2
    exit 1
fi

printf 'yyjson co-link isolation passed second=0.11.1 policy=hidden-local\n'
