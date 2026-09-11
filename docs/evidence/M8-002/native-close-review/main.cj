package wirestack_m7_027_examples
import std.convert.Parsable
import std.env.getVariable
import wirestack as api
import wirestack.net.*
main(): Int64 {
    let port = UInt16.parse(getVariable("WIRESTACK_CLOSE_PORT").getOrThrow())
    let socket = UdpSocket.bind(api.SocketEndpoint(
        api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), port))
    var failed = false
    try {
        socket.close()
        println("CLOSE_RETURNED_SUCCESS")
    } catch (error: api.NetworkException) {
        failed = true
        println("CLOSE_RETURNED_STRUCTURED_ERROR")
        let phaseMatches = match (error.phase) {
            case api.NetworkPhase.TransportClose => true
            case _ => false
        }
        let neverRetry = match (error.retryability) {
            case api.Retryability.Never => true
            case _ => false
        }
        if (!phaseMatches || !neverRetry) { return 3 }
    }
    let terminalFailure = match (socket.state) {
        case SocketState.Failed => true
        case _ => false
    }
    if (failed && !terminalFailure) { return 4 }
    socket.close()
    socket.abort()
    println("REPEATED_TERMINAL_OPERATIONS_RETURNED")
    return 0
}
