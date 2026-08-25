import std.env.*
import std.fs.*
import std.process.*

private func invokingProjectRoot(): Path {
    var path = Path(getCommandLine()[0])
    for (_ in 0..5) { path = path.parent }
    path
}

// Native sources are intentionally rebuilt by the package hook so consumers
// never need a pre-generated archive in their checkout.
private func buildNativeLibrary(): Int64 {
    let packageRoot = getWorkingDirectory()
    let output = invokingProjectRoot().join("target").join("native")
    if (!exists(output)) { Directory.create(output, recursive: true) }
    let source = packageRoot.join("native").join("schema_formats.c")
    let object = output.join("schema_formats.o")
    let archive = output.join("libyjson_schema_formats.a")
    var status = execute("/usr/lib/llvm15/bin/clang",
        ["-O2", "-fPIC", "-Wall", "-Wextra", "-Werror", "-c", source.toString(), "-o", object.toString()],
        workingDirectory: packageRoot)
    if (status == 0) {
        status = execute("ar", ["rcs", archive.toString(), object.toString()], workingDirectory: packageRoot)
    }
    if (status != 0) { println("failed to build yjson_schema_formats native library") }
    status
}

main(): Int64 {
    let args = getCommandLine()
    if (args.size >= 2 && args[1] == "pre-build") { buildNativeLibrary() } else { 0 }
}
