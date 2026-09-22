import std.net.*

func verify(
    label: String, level: Int32, option: Int32, requested: Int32,
    setter: (Int32, Int32, CPointer<Unit>, UIntNative) -> Unit,
    getter: (Int32, Int32, CPointer<Unit>, CPointer<UIntNative>) -> Unit,
    exact!: Bool = true
): Unit {
    let value = LibC.malloc<Int32>()
    let length = LibC.malloc<UIntNative>()
    try {
        unsafe {
            value.write(requested)
            setter(level, option, CPointer<Unit>(value), 4)
            value.write(0)
            length.write(4)
            getter(level, option, CPointer<Unit>(value), length)
            println("${label}: requested=${requested} effective=${value.read()} length=${length.read()}")
            if (length.read() != 4 || (exact && value.read() != requested) || (!exact && value.read() <= 0)) {
                throw Exception("option qualification failed")
            }
        }
    } finally { unsafe { LibC.free(value); LibC.free(length) } }
}

main(): Int64 {
    let v4 = UdpSocket(bindAt: IPSocketAddress("127.0.0.1", 0))
    let v6 = UdpSocket(bindAt: IPSocketAddress("::1", 0))
    let tcp = TcpSocket(IPSocketAddress("127.0.0.1", 9))
    try {
        let s4 = { l: Int32, o: Int32, p: CPointer<Unit>, n: UIntNative => v4.setSocketOption(l,o,p,n) }
        let g4 = { l: Int32, o: Int32, p: CPointer<Unit>, n: CPointer<UIntNative> => v4.getSocketOption(l,o,p,n) }
        let s6 = { l: Int32, o: Int32, p: CPointer<Unit>, n: UIntNative => v6.setSocketOption(l,o,p,n) }
        let g6 = { l: Int32, o: Int32, p: CPointer<Unit>, n: CPointer<UIntNative> => v6.getSocketOption(l,o,p,n) }
        let st = { l: Int32, o: Int32, p: CPointer<Unit>, n: UIntNative => tcp.setSocketOption(l,o,p,n) }
        let gt = { l: Int32, o: Int32, p: CPointer<Unit>, n: CPointer<UIntNative> => tcp.getSocketOption(l,o,p,n) }
        verify("reuse-address",1,2,1,s4,g4)
        verify("reuse-port",1,15,1,s4,g4)
        verify("ipv6-only",41,26,1,s6,g6)
        v4.bind()
        v6.bind()
        verify("receive-buffer",1,8,4096,s4,g4,exact:false)
        verify("send-buffer",1,7,4096,s4,g4,exact:false)
        verify("broadcast",1,6,1,s4,g4)
        verify("multicast-ttl",0,33,255,s4,g4)
        verify("multicast-loop-v4",0,34,0,s4,g4)
        verify("multicast-hop-limit",41,18,255,s6,g6)
        verify("multicast-loop-v6",41,19,0,s6,g6)
        verify("multicast-interface-v6",41,17,0,s6,g6)
        verify("tcp-no-delay",6,1,1,st,gt)
        tcp.keepAlive = Some(SocketKeepAliveConfig())
        verify("tcp-keep-alive",1,9,1,st,gt)
        verify("tcp-keep-idle",6,4,45,st,gt)
        verify("tcp-keep-interval",6,5,5,st,gt)
        verify("tcp-keep-count",6,6,5,st,gt)
        return 0
    } finally { v4.close(); v6.close(); tcp.close() }
}
