import std.env.*
import std.fs.*
import std.process.*

private func buildNativeDependencies(scriptPath: String): Int64 {
    let root = getWorkingDirectory()
    let script = root.join("tools").join("build_native_dependencies.py")
    let status = execute(
        "python3",
        [
            script.toString(), "--root", root.toString(),
            "--cjpm-script-path", scriptPath
        ],
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
        case "pre-build" => buildNativeDependencies(args[0])
        case "pre-check" => buildNativeDependencies(args[0])
        case "pre-test" => buildNativeDependencies(args[0])
        case "pre-bench" => buildNativeDependencies(args[0])
        case "pre-run" => buildNativeDependencies(args[0])
        case "pre-install" => buildNativeDependencies(args[0])
        case "pre-publish" => buildNativeDependencies(args[0])
        case _ => 0
    }
}
