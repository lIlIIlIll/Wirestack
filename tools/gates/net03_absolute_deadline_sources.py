#!/usr/bin/env python3
"""Cangjie probe sources for the NET-03 absolute-deadline harness."""
from __future__ import annotations

# Terminal codes are intentionally typed in the Cangjie probe rather than
# inferred from exception messages.
SOURCES: dict[str, str] = {
    "idle-read": r'''import std.net.*
import std.sync.*
import std.time.*
import std.convert.*

main(args: Array<String>): Int64 {
    let port = UInt16.parse(args[0])
    let budgetMs = Int64.parse(args[1])
    let socket = TcpSocket("127.0.0.1", port)
    socket.connect()
    let epoch = MonoTime.now()
    let go = AtomicBool(false)
    let budgetStart = AtomicInt64(-1)
    let started = AtomicInt64(-1)
    let ended = AtomicInt64(-1)
    let closeStart = AtomicInt64(-1)
    let closeDone = AtomicInt64(-1)
    let deadlineFired = AtomicBool(false)
    let terminalCode = AtomicInt64(0)
    let resultBytes = AtomicInt64(-1)
    let closeCode = AtomicInt64(0)
    let worker = spawn {
        while (!go.load()) {}
        started.store((MonoTime.now() - epoch).toNanoseconds())
        let buffer = Array<Byte>(4096, repeat: 0)
        try {
            let n = socket.read(buffer)
            resultBytes.store(n)
            terminalCode.store(if (n == 0) { 1 } else { 2 })
        } catch (_: SocketTimeoutException) {
            terminalCode.store(3)
        } catch (_: SocketException) {
            terminalCode.store(4)
        } catch (_: Exception) {
            terminalCode.store(5)
        }
        ended.store((MonoTime.now() - epoch).toNanoseconds())
    }
    budgetStart.store((MonoTime.now() - epoch).toNanoseconds())
    Timer.once(budgetMs * Duration.millisecond) {
        =>
        closeStart.store((MonoTime.now() - epoch).toNanoseconds())
        try { socket.close() } catch (_: SocketException) { closeCode.store(1) } catch (_: Exception) { closeCode.store(2) }
        closeDone.store((MonoTime.now() - epoch).toNanoseconds())
        deadlineFired.store(true)
    }
    go.store(true)
    while (!deadlineFired.load()) { sleep(Duration.millisecond) }
    worker.get()
    let terminalBeforeClose = ended.load() >= 0 && ended.load() < closeStart.load()
    println("RESULT scenario=idle-read budgetMs=${budgetMs} budgetStartNs=${budgetStart.load()} opStartNs=${started.load()} terminalBeforeClose=${terminalBeforeClose} closeStartNs=${closeStart.load()} closeDoneNs=${closeDone.load()} terminalNs=${ended.load()} terminalCode=${terminalCode.load()} resultBytes=${resultBytes.load()} closeCode=${closeCode.load()}")
    0
}
''',
    "partial-write": r'''import std.net.*
import std.sync.*
import std.time.*
import std.convert.*

main(args: Array<String>): Int64 {
    let port = UInt16.parse(args[0])
    let budgetMs = Int64.parse(args[1])
    let socket = TcpSocket("127.0.0.1", port)
    socket.connect()
    socket.sendBufferSize = 4096
    let epoch = MonoTime.now()
    let go = AtomicBool(false)
    let budgetStart = AtomicInt64(-1)
    let started = AtomicInt64(-1)
    let ended = AtomicInt64(-1)
    let closeStart = AtomicInt64(-1)
    let closeDone = AtomicInt64(-1)
    let deadlineFired = AtomicBool(false)
    let checkpointFired = AtomicBool(false)
    let terminalCode = AtomicInt64(0)
    let writeCount = AtomicInt64(0)
    let countA = AtomicInt64(-1)
    let countB = AtomicInt64(-1)
    let checkpointNs = AtomicInt64(-1)
    let closeCode = AtomicInt64(0)
    let worker = spawn {
        while (!go.load()) {}
        started.store((MonoTime.now() - epoch).toNanoseconds())
        let payload = Array<Byte>(65536, repeat: 41)
        try {
            while (true) {
                socket.write(payload)
                writeCount.fetchAdd(1)
            }
        } catch (_: SocketTimeoutException) {
            terminalCode.store(1)
        } catch (_: SocketException) {
            terminalCode.store(2)
        } catch (_: Exception) {
            terminalCode.store(3)
        }
        ended.store((MonoTime.now() - epoch).toNanoseconds())
    }
    budgetStart.store((MonoTime.now() - epoch).toNanoseconds())
    let checkpointDelay = if (budgetMs >= 100) { budgetMs / 2 } else { 20 }
    Timer.once(checkpointDelay * Duration.millisecond) {
        =>
        checkpointNs.store((MonoTime.now() - epoch).toNanoseconds())
        countA.store(writeCount.load())
        checkpointFired.store(true)
    }
    Timer.once(budgetMs * Duration.millisecond) {
        =>
        closeStart.store((MonoTime.now() - epoch).toNanoseconds())
        countB.store(writeCount.load())
        try { socket.close() } catch (_: SocketException) { closeCode.store(1) } catch (_: Exception) { closeCode.store(2) }
        closeDone.store((MonoTime.now() - epoch).toNanoseconds())
        deadlineFired.store(true)
    }
    go.store(true)
    while (!deadlineFired.load()) { sleep(Duration.millisecond) }
    worker.get()
    let terminalBeforeClose = ended.load() >= 0 && ended.load() < closeStart.load()
    println("RESULT scenario=partial-write budgetMs=${budgetMs} budgetStartNs=${budgetStart.load()} opStartNs=${started.load()} terminalBeforeClose=${terminalBeforeClose} checkpointFired=${checkpointFired.load()} checkpointNs=${checkpointNs.load()} countA=${countA.load()} countB=${countB.load()} closeStartNs=${closeStart.load()} closeDoneNs=${closeDone.load()} terminalNs=${ended.load()} terminalCode=${terminalCode.load()} closeCode=${closeCode.load()}")
    0
}
''',
    "blocked-connect": r'''import std.net.*
import std.sync.*
import std.time.*
import std.convert.*

main(args: Array<String>): Int64 {
    let port = UInt16.parse(args[0])
    let budgetMs = Int64.parse(args[1])
    let socket = TcpSocket("127.0.0.1", port)
    let epoch = MonoTime.now()
    let go = AtomicBool(false)
    let budgetStart = AtomicInt64(-1)
    let started = AtomicInt64(-1)
    let ended = AtomicInt64(-1)
    let closeStart = AtomicInt64(-1)
    let closeDone = AtomicInt64(-1)
    let deadlineFired = AtomicBool(false)
    let terminalCode = AtomicInt64(0)
    let closeCode = AtomicInt64(0)
    let worker = spawn {
        while (!go.load()) {}
        started.store((MonoTime.now() - epoch).toNanoseconds())
        try {
            socket.connect()
            terminalCode.store(1)
        } catch (_: SocketTimeoutException) {
            terminalCode.store(2)
        } catch (_: SocketException) {
            terminalCode.store(3)
        } catch (_: Exception) {
            terminalCode.store(4)
        }
        ended.store((MonoTime.now() - epoch).toNanoseconds())
    }
    budgetStart.store((MonoTime.now() - epoch).toNanoseconds())
    Timer.once(budgetMs * Duration.millisecond) {
        =>
        closeStart.store((MonoTime.now() - epoch).toNanoseconds())
        try { socket.close() } catch (_: SocketException) { closeCode.store(1) } catch (_: Exception) { closeCode.store(2) }
        closeDone.store((MonoTime.now() - epoch).toNanoseconds())
        deadlineFired.store(true)
    }
    go.store(true)
    while (!deadlineFired.load()) { sleep(Duration.millisecond) }
    worker.get()
    let terminalBeforeClose = ended.load() >= 0 && ended.load() < closeStart.load()
    println("RESULT scenario=blocked-connect budgetMs=${budgetMs} budgetStartNs=${budgetStart.load()} opStartNs=${started.load()} terminalBeforeClose=${terminalBeforeClose} closeStartNs=${closeStart.load()} closeDoneNs=${closeDone.load()} terminalNs=${ended.load()} terminalCode=${terminalCode.load()} closeCode=${closeCode.load()}")
    0
}
''',
    "blocked-accept": r'''import std.net.*
import std.sync.*
import std.time.*
import std.convert.*

main(args: Array<String>): Int64 {
    let port = UInt16.parse(args[0])
    let budgetMs = Int64.parse(args[1])
    let listener = TcpServerSocket(bindAt: port)
    listener.bind()
    let epoch = MonoTime.now()
    let go = AtomicBool(false)
    let budgetStart = AtomicInt64(-1)
    let started = AtomicInt64(-1)
    let ended = AtomicInt64(-1)
    let closeStart = AtomicInt64(-1)
    let closeDone = AtomicInt64(-1)
    let deadlineFired = AtomicBool(false)
    let terminalCode = AtomicInt64(0)
    let closeCode = AtomicInt64(0)
    let worker = spawn {
        while (!go.load()) {}
        started.store((MonoTime.now() - epoch).toNanoseconds())
        try {
            let accepted = listener.accept()
            terminalCode.store(1)
            accepted.close()
        } catch (_: SocketTimeoutException) {
            terminalCode.store(2)
        } catch (_: SocketException) {
            terminalCode.store(3)
        } catch (_: Exception) {
            terminalCode.store(4)
        }
        ended.store((MonoTime.now() - epoch).toNanoseconds())
    }
    budgetStart.store((MonoTime.now() - epoch).toNanoseconds())
    Timer.once(budgetMs * Duration.millisecond) {
        =>
        closeStart.store((MonoTime.now() - epoch).toNanoseconds())
        try { listener.close() } catch (_: SocketException) { closeCode.store(1) } catch (_: Exception) { closeCode.store(2) }
        closeDone.store((MonoTime.now() - epoch).toNanoseconds())
        deadlineFired.store(true)
    }
    go.store(true)
    while (!deadlineFired.load()) { sleep(Duration.millisecond) }
    worker.get()
    let terminalBeforeClose = ended.load() >= 0 && ended.load() < closeStart.load()
    println("RESULT scenario=blocked-accept budgetMs=${budgetMs} budgetStartNs=${budgetStart.load()} opStartNs=${started.load()} terminalBeforeClose=${terminalBeforeClose} closeStartNs=${closeStart.load()} closeDoneNs=${closeDone.load()} terminalNs=${ended.load()} terminalCode=${terminalCode.load()} closeCode=${closeCode.load()}")
    0
}
''',
}

EXPECTED_TERMINALS = {
    "idle-read": {1, 4},
    "partial-write": {2},
    "blocked-connect": {3},
    "blocked-accept": {3},
}
