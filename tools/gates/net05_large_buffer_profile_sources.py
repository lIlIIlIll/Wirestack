"""Cangjie probe source for M0-010 / GATE-NET-05."""

RECEIVE_SOURCE = r'''import std.net.*
import std.time.*
import std.convert.*

main(args: Array<String>): Int64 {
    let host = args[0]
    let port = UInt16.parse(args[1])
    let expected = Int64.parse(args[2])
    let bufferSize = Int64.parse(args[3])
    let reportReads = args[4] == "verbose"
    let socket = TcpSocket(host, port)
    socket.connect()
    let buffer = Array<Byte>(bufferSize, repeat: 0)
    let started = MonoTime.now()
    var total: Int64 = 0
    var reads: Int64 = 0
    var invalid: Int64 = 0
    var eof: Bool = false
    while (total < expected) {
        let n = socket.read(buffer)
        if (n == 0) {
            eof = true
            break
        }
        var index: Int64 = 0
        while (index < n) {
            if (buffer[index] != 37u8) {
                invalid += 1
            }
            index += 1
        }
        total += n
        reads += 1
        if (reportReads) {
            println("READ size=${n}")
        }
    }
    let durationNs = (MonoTime.now() - started).toNanoseconds()
    var closeCode: Int64 = 0
    try {
        socket.close()
    } catch (_: SocketException) {
        closeCode = 1
    } catch (_: Exception) {
        closeCode = 2
    }
    println("RESULT bytes=${total} readCalls=${reads} invalid=${invalid} eof=${eof} durationNs=${durationNs} closeCode=${closeCode} bufferSize=${bufferSize}")
    if (total == expected && invalid == 0 && !eof && closeCode == 0) { 0 } else { 1 }
}
'''
