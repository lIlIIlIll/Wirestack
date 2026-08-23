import std.env.*
import std.fs.*
import std.process.*

private func buildLinuxTlsProvider(): Int64 {
    let root = getWorkingDirectory()
    let script = root.join("tools").join("build_linux_tls_provider.py")
    let status = execute(
        "python3",
        [script.toString(), "--repo", root.toString()],
        workingDirectory: root
    )
    if (status != 0) {
        println("failed to build the pinned Linux TLS provider")
    }
    status
}

main(): Int64 {
    let args = getCommandLine()
    if (args.size < 2) {
        return 0
    }
    match (args[1]) {
        case "pre-build" => buildLinuxTlsProvider()
        case "pre-check" => buildLinuxTlsProvider()
        case "pre-test" => buildLinuxTlsProvider()
        case "pre-bench" => buildLinuxTlsProvider()
        case "pre-run" => buildLinuxTlsProvider()
        case "pre-install" => buildLinuxTlsProvider()
        case "pre-publish" => buildLinuxTlsProvider()
        case _ => 0
    }
}
