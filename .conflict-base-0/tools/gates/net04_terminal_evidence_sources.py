"""Cangjie probe sources for M0-009 / GATE-NET-04."""

PEER_SOURCE = r'''import std.net.*
import std.time.*
import std.convert.*

main(args: Array<String>): Int64 {
    let port = UInt16.parse(args[0])
    let s = TcpSocket("127.0.0.1", port)
    s.connect()
    let epoch = MonoTime.now()
    let startNs = (MonoTime.now() - epoch).toNanoseconds()
    let buffer = Array<Byte>(4096, repeat: 0)
    var code: Int64 = 0
    var bytes: Int64 = -1
    try {
        let n = s.read(buffer)
        bytes = n
        code = if (n == 0) { 1 } else { 2 }
    } catch (_: SocketTimeoutException) {
        code = 3
    } catch (_: SocketException) {
        code = 4
    } catch (_: Exception) {
        code = 5
    }
    let endNs = (MonoTime.now() - epoch).toNanoseconds()
    var closeCode: Int64 = 0
    try { s.close() } catch (_: SocketException) { closeCode = 1 } catch (_: Exception) { closeCode = 2 }
    println("RESULT scenario=peer-terminal opStartNs=${startNs} terminalNs=${endNs} terminalCode=${code} bytes=${bytes} closeCode=${closeCode}")
    0
}
'''

LOCAL_CLOSE_SOURCE = r'''import std.net.*
import std.sync.*
import std.time.*
import std.convert.*

main(args: Array<String>): Int64 {
    let port = UInt16.parse(args[0])
    let delayMs = Int64.parse(args[1])
    let s = TcpSocket("127.0.0.1", port)
    s.connect()
    let epoch = MonoTime.now()
    let started = AtomicInt64(-1)
    let ended = AtomicInt64(-1)
    let code = AtomicInt64(0)
    let bytes = AtomicInt64(-1)
    let f = spawn {
        started.store((MonoTime.now() - epoch).toNanoseconds())
        let buffer = Array<Byte>(4096, repeat: 0)
        try {
            let n = s.read(buffer)
            bytes.store(n)
            code.store(if (n == 0) { 1 } else { 2 })
        } catch (_: SocketTimeoutException) {
            code.store(3)
        } catch (_: SocketException) {
            code.store(4)
        } catch (_: Exception) {
            code.store(5)
        }
        ended.store((MonoTime.now() - epoch).toNanoseconds())
    }
    while (started.load() < 0) { sleep(Duration.millisecond) }
    sleep(delayMs * Duration.millisecond)
    let before = ended.load() >= 0
    let closeStart = (MonoTime.now() - epoch).toNanoseconds()
    var closeCode: Int64 = 0
    try { s.close() } catch (_: SocketException) { closeCode = 1 } catch (_: Exception) { closeCode = 2 }
    let closeDone = (MonoTime.now() - epoch).toNanoseconds()
    f.get()
    println("RESULT scenario=local-close delayMs=${delayMs} opStartNs=${started.load()} terminalBeforeClose=${before} closeStartNs=${closeStart} closeDoneNs=${closeDone} terminalNs=${ended.load()} terminalCode=${code.load()} bytes=${bytes.load()} closeCode=${closeCode}")
    0
}
'''

RACE_SOURCE = r'''import std.net.*
import std.sync.*
import std.time.*
import std.convert.*

main(args: Array<String>): Int64 {
    let port = UInt16.parse(args[0])
    let localDelayMs = Int64.parse(args[1])
    let seed = Int64.parse(args[2])
    let s = TcpSocket("127.0.0.1", port)
    s.connect()
    let epoch = MonoTime.now()
    let started = AtomicInt64(-1)
    let ended = AtomicInt64(-1)
    let code = AtomicInt64(0)
    let bytes = AtomicInt64(-1)
    let f = spawn {
        started.store((MonoTime.now() - epoch).toNanoseconds())
        let buffer = Array<Byte>(4096, repeat: 0)
        try {
            let n = s.read(buffer)
            bytes.store(n)
            code.store(if (n == 0) { 1 } else { 2 })
        } catch (_: SocketTimeoutException) {
            code.store(3)
        } catch (_: SocketException) {
            code.store(4)
        } catch (_: Exception) {
            code.store(5)
        }
        ended.store((MonoTime.now() - epoch).toNanoseconds())
    }
    while (started.load() < 0) { sleep(Duration.millisecond) }
    sleep(localDelayMs * Duration.millisecond)
    let before = ended.load() >= 0
    let closeStart = (MonoTime.now() - epoch).toNanoseconds()
    var closeCode: Int64 = 0
    try { s.close() } catch (_: SocketException) { closeCode = 1 } catch (_: Exception) { closeCode = 2 }
    let closeDone = (MonoTime.now() - epoch).toNanoseconds()
    f.get()
    println("RESULT scenario=close-read-race seed=${seed} localDelayMs=${localDelayMs} opStartNs=${started.load()} terminalBeforeLocalClose=${before} closeStartNs=${closeStart} closeDoneNs=${closeDone} terminalNs=${ended.load()} terminalCode=${code.load()} bytes=${bytes.load()} closeCode=${closeCode}")
    0
}
'''

ABORT_SOURCE = r'''import std.net.*
main(): Int64 {
    let s = TcpSocket("127.0.0.1", 1u16)
    s.abort()
    0
}
'''

CANCEL_SOURCE = r'''import std.net.*
main(): Int64 {
    let s = TcpSocket("127.0.0.1", 1u16)
    s.cancel()
    0
}
'''
