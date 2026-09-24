package wirestack_m9_002_compatibility

import wirestack.net.SocketOption

func classify(option: SocketOption): Int64 {
    match (option) {
        case SocketOption.ReuseAddress(_) => 1
        case SocketOption.ReusePort(_) => 2
        case SocketOption.NoDelay(_) => 3
        case SocketOption.KeepAlive(_) => 4
        case SocketOption.Broadcast(_) => 5
        case SocketOption.ReceiveBuffer(_) => 6
        case SocketOption.SendBuffer(_) => 7
        case SocketOption.MulticastTtl(_) => 8
    }
}

main(): Int64 {
    if (classify(SocketOption.NoDelay(true)) != 3) { return 1 }
    println("OLD_EXHAUSTIVE_CLIENT_PASS")
    0
}
