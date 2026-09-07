import std.process.*
import std.env.*

main(): Int64 {
    let args = getCommandLine()
    if (args.size >= 2 && args[1] == "pre-build") {
        execute("python3", "../../scripts/build_native_scanner.py", "--out-dir", "target/native")
    } else {
        0
    }
}
