package wirestack_m8_002_native

import std.time.MonoTime
import wirestack as api
import wirestack.net.*

class SendFailureClock <: api.MonotonicClock {
    let socket: UdpSocket
    let peer: api.NetworkEndpoint
    let origin = MonoTime.now()

    init(socket: UdpSocket, peer: api.NetworkEndpoint) {
        this.socket = socket
        this.peer = peer
    }

    public func now(): MonoTime {
        if (socket.isClosed()) { return origin + 2 * Duration.second }
        try {
            let _ = socket.sendTo(peer, api.ByteSpan([1u8]))
        } catch (error: api.NetworkException) {
            match (error.code) {
                case api.NetworkErrorCode.ConcurrentOperation => socket.abort()
                case _ => throw error
            }
        }
        origin
    }
}

func endpoint(): api.SocketEndpoint {
    api.SocketEndpoint(api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0u16)
}

main(): Int64 {
    let sink = UdpSocket.bind(endpoint())
    let sender = UdpSocket.bind(endpoint())
    try {
        let peer = sink.localEndpoint.getOrThrow()
        let clock = SendFailureClock(sender, peer)
        let context = api.OperationContext(deadline: Some(api.Deadline.after(Duration.second, clock: clock)))
        try {
            let _ = sender.sendTo(peer, api.ByteSpan([2u8]), context: context)
            throw Exception("admitted native failure did not occur")
        } catch (error: api.NetworkException) {
            match ((error.code, error.retryability)) {
                case (api.NetworkErrorCode.TimedOut, api.Retryability.Never) =>
                    println("ADMITTED_SEND_FAILURE_NEVER_RETRY"); 0
                case (api.NetworkErrorCode.TimedOut, api.Retryability.Temporary) =>
                    println("ADMITTED_SEND_FAILURE_WRONGLY_RETRYABLE"); 42
                case _ => throw error
            }
        }
    } finally {
        sender.close()
        sink.close()
    }
}
