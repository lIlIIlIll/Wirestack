import std.env.*
import std.fs.*
import std.process.*

private func buildTlsProvider(): Int64 {
    let root = getWorkingDirectory()
    let script = root.join("tools").join("build_tls_provider.py")
    let status = execute(
        "python3",
        [script.toString(), "--repo", root.toString()],
        workingDirectory: root
    )
    if (status != 0) {
        println("failed to build the selected TLS provider")
    }
    status
}

private func buildLinuxResolver(): Int64 {
    let root = getWorkingDirectory()
    let script = root.join("tools").join("build_linux_resolver.py")
    let status = execute(
        "python3",
        [script.toString(), "--root", root.toString(), "--quiet"],
        workingDirectory: root
    )
    if (status != 0) {
        println("failed to build the pinned Linux resolver bridge")
    }
    status
}

private func buildLinuxNativeDependencies(): Int64 {
    let tlsStatus = buildTlsProvider()
    if (tlsStatus != 0) {
        return tlsStatus
    }
    buildLinuxResolver()
}

main(): Int64 {
    let args = getCommandLine()
    if (args.size < 2) {
        return 0
    }
    match (args[1]) {
        case "pre-build" => buildLinuxNativeDependencies()
        case "pre-check" => buildLinuxNativeDependencies()
        case "pre-test" => buildLinuxNativeDependencies()
        case "pre-bench" => buildLinuxNativeDependencies()
        case "pre-run" => buildLinuxNativeDependencies()
        case "pre-install" => buildLinuxNativeDependencies()
        case "pre-publish" => buildLinuxNativeDependencies()
        case _ => 0
    }
}
