import std.env.*
import std.fs.*
import std.process.*

private func invokingProjectRoot(): Path {
    // <invoking-project>/build-script-cache/<profile>/<package>/bin/build-script
    var path = Path(getCommandLine()[0])
    for (_ in 0..5) {
        path = path.parent
    }
    path
}

private func buildNativeScanner(): Int64 {
    let packageRoot = getWorkingDirectory()
    let localScript = packageRoot.join("scripts").join("build_native_scanner.py")
    let suiteRoot = if (exists(localScript)) { packageRoot } else { packageRoot.parent.parent }
    let script = suiteRoot.join("scripts").join("build_native_scanner.py")
    let output = invokingProjectRoot().join("target").join("native")
    let status = execute(
        "python3",
        [script.toString(), "--out-dir", output.toString(), "--without-yyjson"],
        workingDirectory: suiteRoot
    )
    if (status != 0) {
        println("failed to build yjson native scanner")
    }
    status
}

main(): Int64 {
    let args = getCommandLine()
    if (args.size < 2) {
        return 0
    }
    match (args[1]) {
        case "pre-build" => buildNativeScanner()
        case _ => 0
    }
}
