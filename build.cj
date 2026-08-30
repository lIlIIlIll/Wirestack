import std.env.*
import std.fs.*
import std.process.*

private func buildNativeDependencies(): Int64 {
    let root = getWorkingDirectory()
    let script = root.join("tools").join("build_native_dependencies.py")
    let status = execute(
        "python3",
        [script.toString(), "--root", root.toString()],
        workingDirectory: root
    )
    if (status != 0) {
        println("failed to build native dependencies for the selected platform")
    }
    status
}

main(): Int64 {
    let args = getCommandLine()
    if (args.size < 2) {
        return 0
    }
    match (args[1]) {
        case "pre-build" => buildNativeDependencies()
        case "pre-check" => buildNativeDependencies()
        case "pre-test" => buildNativeDependencies()
        case "pre-bench" => buildNativeDependencies()
        case "pre-run" => buildNativeDependencies()
        case "pre-install" => buildNativeDependencies()
        case "pre-publish" => buildNativeDependencies()
        case _ => 0
    }
}
