"""Cangjie stress probe source for M0-011 / GATE-NET-06."""

STRESS_SOURCE = r'''import std.net.*
import std.sync.*
import std.time.*
import std.convert.*

func closeSocket(socket: TcpSocket): Int64 {
    try {
        socket.close()
        return 0
    } catch (_: SocketException) {
        return 1
    } catch (_: Exception) {
        return 2
    }
}

main(args: Array<String>): Int64 {
    let mode = args[0]
    let port = UInt16.parse(args[1])
    let requested = Int64.parse(args[2])
    let mixedSoak = mode == "mixed-soak"
    var connected: Int64 = 0
    var completed: Int64 = 0
    var socketErrors: Int64 = 0
    var otherErrors: Int64 = 0
    var eof: Int64 = 0
    var bytesWritten: Int64 = 0
    var bytesRead: Int64 = 0
    var closeErrors: Int64 = 0
    let started = MonoTime.now()

    var iteration: Int64 = 0
    while ((mixedSoak && (MonoTime.now() - started).toNanoseconds() < requested * 1000000000) ||
           (!mixedSoak && iteration < requested)) {
        let socket = TcpSocket("127.0.0.1", port)
        try {
            socket.connect()
            connected += 1
            let effectiveMode = if (!mixedSoak) {
                mode
            } else if (iteration % 4 == 0) {
                "connect-close"
            } else if (iteration % 4 == 1) {
                "echo-close"
            } else if (iteration % 4 == 2) {
                "peer-reset"
            } else {
                "close-during-read"
            }
            if (effectiveMode == "connect-close") {
                closeErrors += closeSocket(socket)
                completed += 1
            } else if (effectiveMode == "echo-close") {
                let payload = Array<Byte>(64, repeat: 41)
                let buffer = Array<Byte>(64, repeat: 0)
                socket.write(payload)
                bytesWritten += 64
                var received: Int64 = 0
                var valid = true
                while (received < 64) {
                    let n = socket.read(buffer)
                    if (n == 0) {
                        eof += 1
                        break
                    }
                    var index: Int64 = 0
                    while (index < n) {
                        if (buffer[index] != 41u8) { valid = false }
                        index += 1
                    }
                    received += n
                }
                bytesRead += received
                closeErrors += closeSocket(socket)
                if (received == 64 && valid) { completed += 1 } else { otherErrors += 1 }
            } else if (effectiveMode == "peer-reset") {
                let buffer = Array<Byte>(64, repeat: 0)
                try {
                    let n = socket.read(buffer)
                    if (n == 0) { eof += 1 } else { bytesRead += n }
                } catch (_: SocketException) {
                    socketErrors += 1
                } catch (_: Exception) {
                    otherErrors += 1
                }
                closeErrors += closeSocket(socket)
                completed += 1
            } else if (effectiveMode == "close-during-read") {
                let terminal = AtomicInt64(0)
                let startedRead = SyncCounter(1)
                let future = spawn {
                    let buffer = Array<Byte>(64, repeat: 0)
                    startedRead.dec()
                    try {
                        let n = socket.read(buffer)
                        terminal.store(if (n == 0) { 1 } else { 2 })
                    } catch (_: SocketException) {
                        terminal.store(3)
                    } catch (_: Exception) {
                        terminal.store(4)
                    }
                }
                startedRead.waitUntilZero()
                closeErrors += closeSocket(socket)
                future.get()
                let code = terminal.load()
                if (code == 3) {
                    socketErrors += 1
                    completed += 1
                } else if (code == 1) {
                    eof += 1
                    completed += 1
                } else {
                    otherErrors += 1
                }
            } else {
                closeErrors += closeSocket(socket)
                println("RESULT mode=${mode} requested=${requested} iterations=${iteration} connected=${connected} completed=${completed} socketErrors=${socketErrors} otherErrors=${otherErrors} eof=${eof} bytesWritten=${bytesWritten} bytesRead=${bytesRead} closeErrors=${closeErrors} durationNs=0 unknownMode=true")
                return 2
            }
        } catch (_: SocketException) {
            socketErrors += 1
            closeErrors += closeSocket(socket)
            completed += 1
        } catch (_: Exception) {
            otherErrors += 1
            closeErrors += closeSocket(socket)
            completed += 1
        }
        iteration += 1
    }
    let durationNs = (MonoTime.now() - started).toNanoseconds()
    println("RESULT mode=${mode} requested=${requested} iterations=${iteration} connected=${connected} completed=${completed} socketErrors=${socketErrors} otherErrors=${otherErrors} eof=${eof} bytesWritten=${bytesWritten} bytesRead=${bytesRead} closeErrors=${closeErrors} durationNs=${durationNs} unknownMode=false")
    let connectionTotalValid = if (mixedSoak || mode == "peer-reset") {
        connected <= iteration
    } else {
        connected == iteration
    }
    if (connectionTotalValid && completed == iteration && otherErrors == 0 && closeErrors == 0) { 0 } else { 1 }
}
'''
