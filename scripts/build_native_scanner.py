#!/usr/bin/env python3
import os
import pathlib
import platform
import shutil
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
NATIVE_DIR = ROOT / "native"
DEFAULT_OUT_DIR = ROOT / "target" / "native"
SUPPORTED_SYSTEM = "Linux"
SUPPORTED_MACHINES = {"x86_64", "amd64"}


def find_tool(env_name: str, default: str) -> str:
    configured = os.environ.get(env_name)
    if configured:
        return configured
    return shutil.which(default) or default


def main() -> int:
    system = platform.system()
    machine = platform.machine().lower()
    if system != SUPPORTED_SYSTEM or machine not in SUPPORTED_MACHINES:
        raise SystemExit(
            "yjson_native_accel supports Linux x86_64 only; "
            f"current build host is {system} {platform.machine()}"
        )
    out_dir = DEFAULT_OUT_DIR
    build_yyjson = False
    yyjson_mode_explicit = False
    args = list(sys.argv[1:])
    while args:
        option = args.pop(0)
        if option == "--out-dir" and args:
            out_dir = pathlib.Path(args.pop(0)).resolve()
        elif option == "--with-yyjson":
            build_yyjson = True
            yyjson_mode_explicit = True
        elif option == "--without-yyjson":
            build_yyjson = False
            yyjson_mode_explicit = True
        else:
            raise SystemExit(
                "usage: build_native_scanner.py [--out-dir DIR] "
                "[--with-yyjson|--without-yyjson]"
            )
    lib = out_dir / "libyjson_scanner.a"
    scanner_obj = out_dir / "yjson_scanner.o"
    compact_obj = out_dir / "yjson_compact.o"
    yyjson_adapter_obj = out_dir / "yjson_yyjson.o"
    yyjson_obj = out_dir / "yyjson.o"
    yyjson_lib = out_dir / "libyjson_yyjson.a"
    out_dir.mkdir(parents=True, exist_ok=True)
    cc = find_tool("CC", "clang")
    ar = find_tool("AR", "ar")
    sources = [NATIVE_DIR / "yjson_scanner.c", NATIVE_DIR / "yjson_compact.c"]
    headers = [NATIVE_DIR / "yjson_scanner.h", NATIVE_DIR / "yjson_compact.h"]
    objects = [scanner_obj, compact_obj]

    needs_build = not lib.exists() or not all(obj.exists() for obj in objects)
    if not needs_build:
        lib_mtime = lib.stat().st_mtime
        needs_build = any(path.stat().st_mtime > lib_mtime for path in sources + headers)

    if needs_build:
        for source, obj in zip(sources, objects):
            compile_cmd = [
                cc,
                "-std=c11",
                "-O3",
                "-fPIC",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-c",
                str(source),
                "-o",
                str(obj),
            ]
            subprocess.check_call(compile_cmd, cwd=str(ROOT))
        subprocess.check_call([ar, "rcs", str(lib)] + [str(obj) for obj in objects], cwd=str(ROOT))

    legacy_setting = os.environ.get("YJSON_BUILD_YYJSON")
    if legacy_setting is not None and not yyjson_mode_explicit:
        build_yyjson = legacy_setting != "0"
    yyjson_dir = NATIVE_DIR / "vendor" / "yyjson"
    yyjson_sources = [NATIVE_DIR / "yjson_yyjson.c", yyjson_dir / "yyjson.c"]
    yyjson_headers = [NATIVE_DIR / "yjson_yyjson.h", yyjson_dir / "yyjson.h",
                      NATIVE_DIR / "yjson_compact.h"]
    if build_yyjson and all(path.exists() for path in yyjson_sources + yyjson_headers):
        yyjson_needs_build = not yyjson_lib.exists() or not yyjson_adapter_obj.exists() or not yyjson_obj.exists()
        if not yyjson_needs_build:
            yyjson_mtime = yyjson_lib.stat().st_mtime
            yyjson_needs_build = any(path.stat().st_mtime > yyjson_mtime
                                     for path in yyjson_sources + yyjson_headers)
        if yyjson_needs_build:
            own_flags = [cc, "-std=c11", "-O3", "-fPIC", "-Wall", "-Wextra",
                         "-Werror", "-DNDEBUG"]
            # Keep the vendored yyjson implementation local to the final
            # Cangjie shared package. This prevents ELF symbol interposition
            # when an application independently links another yyjson version.
            vendor_flags = [cc, "-std=c11", "-O3", "-fPIC", "-fvisibility=hidden",
                            '-Dyyjson_api=__attribute__((visibility("hidden")))',
                            "-Wall", "-Wextra", "-DNDEBUG"]
            subprocess.check_call(own_flags + ["-I", str(NATIVE_DIR), "-I", str(yyjson_dir),
                "-c", str(NATIVE_DIR / "yjson_yyjson.c"), "-o", str(yyjson_adapter_obj)], cwd=str(ROOT))
            subprocess.check_call(vendor_flags + ["-I", str(yyjson_dir),
                "-c", str(yyjson_dir / "yyjson.c"), "-o", str(yyjson_obj)], cwd=str(ROOT))
            subprocess.check_call([ar, "rcs", str(yyjson_lib), str(yyjson_adapter_obj), str(yyjson_obj)],
                                  cwd=str(ROOT))

    return 0


if __name__ == "__main__":
    sys.exit(main())
