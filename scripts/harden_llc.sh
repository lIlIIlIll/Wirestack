#!/usr/bin/env bash
# Wrap the SDK llc so SIGSEGV crashes while lowering Cangjie bitcode do
# not fail the gate. Some GitHub runner CPU models crash deterministically
# inside the nightly's bundled libLLVM-15 on previously-successful IR
# (exit 139 / 0xC0000005). The wrapper escalates through bounded retries,
# glibc AVX-512 hwcaps disabling, -O1 lowering, and finally assembly
# emission assembled with GNU as, without touching product code. The real
# binary is preserved once as llc.yjson-real; the wrapper itself is always
# rewritten to this revision (warm runner VMs persist the tool cache).
set -euo pipefail

cjc_path="$(command -v cjc)" || {
    echo "harden_llc: cjc not found on PATH" >&2
    exit 1
}
sdk_bin="$(cd "$(dirname "$cjc_path")/../third_party/llvm/bin" && pwd)"
llc="$sdk_bin/llc"

if [[ ! -f "$llc" ]]; then
    echo "harden_llc: llc not found at $llc" >&2
    exit 1
fi
if [[ -f "$llc.yjson-real" ]]; then
    echo "harden_llc: real binary already preserved at $llc.yjson-real"
else
    mv "$llc" "$llc.yjson-real"
fi

cat > "$llc" <<'WRAPPER'
#!/usr/bin/env bash
dir="$(cd "$(dirname "$0")" && pwd)"
args=("$@")
attempt=1
asm_out=""
while :; do
    "$dir/llc.yjson-real" "${args[@]}"
    status=$?
    if [[ "$status" -eq 0 ]] && [[ -n "$asm_out" ]]; then
        # Assembly emission succeeded where object emission crashed;
        # finish with GNU as, an independent implementation.
        as --64 -o "$asm_out" "${asm_out%.o}.s"
        astatus=$?
        rm -f "${asm_out%.o}.s"
        exit "$astatus"
    fi
    if [[ "$status" -ne 139 ]]; then
        exit "$status"
    fi
    if [[ -n "${YJSON_LLC_STACK_DIAGNOSTICS:-}" ]]; then
        python3 "$YJSON_LLC_STACK_PROBE" "$dir/llc.yjson-real" "${args[@]}"
        # A diagnostic success must not turn a failed gate green.
        exit 139
    fi
    echo "llc attempt $attempt crashed with SIGSEGV" >&2
    case "$attempt" in
        2)
            # glibc's AVX-512-dispatched routines are a known trigger
            # class for crashes in the bundled libLLVM-15.
            export GLIBC_TUNABLES="${GLIBC_TUNABLES:+${GLIBC_TUNABLES}:}glibc.cpu.hwcaps=-AVX512F,-AVX512BW,-AVX512VL,-AVX512DQ,-AVX512CD"
            echo "llc: retrying with AVX-512 hwcaps disabled in glibc" >&2
            ;;
        3)
            downgraded=()
            for arg in "${args[@]}"; do
                if [[ "$arg" == "-O2" ]]; then
                    downgraded+=(-O1)
                else
                    downgraded+=("$arg")
                fi
            done
            args=("${downgraded[@]}")
            echo "llc: falling back to -O1 codegen for this host" >&2
            ;;
        4)
            # Deterministic crash on this host: emit assembly and assemble
            # with GNU as, bypassing the LLVM MC object writer entirely.
            out=""
            next_is_out=0
            asm_args=()
            for arg in "${args[@]}"; do
                if [[ "$next_is_out" -eq 1 ]]; then
                    out="$arg"
                    asm_args+=("${arg%.o}.s")
                    next_is_out=0
                elif [[ "$arg" == "--filetype=obj" ]]; then
                    asm_args+=(--filetype=asm)
                elif [[ "$arg" == "-o" ]]; then
                    asm_args+=("$arg")
                    next_is_out=1
                else
                    asm_args+=("$arg")
                fi
            done
            if [[ -z "$out" ]]; then
                echo "llc: cannot locate -o path; cannot fall back to assembly" >&2
                exit 139
            fi
            if ! command -v as >/dev/null 2>&1; then
                echo "llc: GNU as unavailable; cannot fall back to assembly" >&2
                exit 139
            fi
            args=("${asm_args[@]}")
            asm_out="$out"
            echo "llc: falling back to --filetype=asm + GNU as for this host" >&2
            ;;
    esac
    if [[ "$attempt" -ge 5 ]]; then
        rm -f "${asm_out:+${asm_out%.o}.s}"
        exit 139
    fi
    attempt=$((attempt + 1))
done
WRAPPER
chmod +x "$llc"
echo "harden_llc: retry wrapper installed at $llc"
