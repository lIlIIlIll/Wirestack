import std.net.*
import std.sync.*
import std.time.*
import std.convert.*
import std.collection.*

main(args: Array<String>): Int64 {
    let taskCount = Int64.parse(args[0])
    let minimumHeartbeats = Int64.parse(args[1])
    let intervalMs = Int64.parse(args[2])
    let ready = AtomicInt64(0)
    let gate = AtomicBool(false)
    let stopHeartbeat = AtomicBool(false)
    let heartbeatCount = AtomicInt64(0)
    let completed = AtomicInt64(0)
    let starts = Array<AtomicInt64>(taskCount, { _ => AtomicInt64(-1) })
    let ends = Array<AtomicInt64>(taskCount, { _ => AtomicInt64(-1) })
    let codes = Array<AtomicInt64>(taskCount, { _ => AtomicInt64(0) })
    let epoch = MonoTime.now()
    let futures = ArrayList<Future<Unit>>()

    let heartbeat = spawn {
        var index: Int64 = 0
        while (!stopHeartbeat.load() || index < minimumHeartbeats) {
            let elapsed = (MonoTime.now() - epoch).toNanoseconds()
            println("HEARTBEAT index=${index} elapsedNs=${elapsed}")
            heartbeatCount.fetchAdd(1)
            sleep(intervalMs * Duration.millisecond)
            index += 1
        }
    }

    var i: Int64 = 0
    while (i < taskCount) {
        let taskIndex = i
        futures.add(spawn {
            ready.fetchAdd(1)
            while (!gate.load()) {
                sleep(Duration.millisecond)
            }
            let started = (MonoTime.now() - epoch).toNanoseconds()
            var code: Int64 = 0
            try {
                let socket = TcpSocket("localhost", 1u16)
                socket.close()
                code = 1
            } catch (_: SocketException) {
                code = 2
            } catch (_: Exception) {
                code = 3
            }
            let ended = (MonoTime.now() - epoch).toNanoseconds()
            starts[taskIndex].store(started)
            ends[taskIndex].store(ended)
            codes[taskIndex].store(code)
            completed.fetchAdd(1)
        })
        i += 1
    }

    while (ready.load() < taskCount) {
        sleep(Duration.millisecond)
    }
    let releaseNs = (MonoTime.now() - epoch).toNanoseconds()
    gate.store(true)

    for (future in futures) {
        future.get()
    }
    stopHeartbeat.store(true)
    heartbeat.get()
    println("RELEASE tasks=${taskCount} elapsedNs=${releaseNs}")
    var resultIndex: Int64 = 0
    while (resultIndex < taskCount) {
        println("RESOLVE index=${resultIndex} startNs=${starts[resultIndex].load()} endNs=${ends[resultIndex].load()} code=${codes[resultIndex].load()}")
        resultIndex += 1
    }
    println("SUMMARY tasks=${taskCount} completed=${completed.load()} heartbeats=${heartbeatCount.load()}")
    return 0
}
