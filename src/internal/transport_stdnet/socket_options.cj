package wirestack.internal.transport_stdnet

import std.net as native
import wirestack as api

/** Provider-internal option kinds; no native constants cross this boundary. */
public enum StdSocketOptionName {
    | ReuseAddress | ReusePort | NoDelay | KeepAlive | Broadcast
    | ReceiveBuffer | SendBuffer | MulticastTtl | Ipv6Only
    | MulticastInterface | MulticastHopLimit | MulticastLoopback
}

/** An immutable, normalized option passed from the public facade. */
public struct StdSocketOption {
    public let name: StdSocketOptionName
    public let value: Int64
    public init(name: StdSocketOptionName, value: Int64) {
        this.name = name
        this.value = value
    }
}

public enum StdSocketOptionTarget { | Listener | Tcp | Udp }

internal func optionIndex(name: StdSocketOptionName): Int64 {
    match (name) {
        case StdSocketOptionName.ReuseAddress => 0
        case StdSocketOptionName.ReusePort => 1
        case StdSocketOptionName.NoDelay => 2
        case StdSocketOptionName.KeepAlive => 3
        case StdSocketOptionName.Broadcast => 4
        case StdSocketOptionName.ReceiveBuffer => 5
        case StdSocketOptionName.SendBuffer => 6
        case StdSocketOptionName.MulticastTtl => 7
        case StdSocketOptionName.Ipv6Only => 8
        case StdSocketOptionName.MulticastInterface => 9
        case StdSocketOptionName.MulticastHopLimit => 10
        case StdSocketOptionName.MulticastLoopback => 11
    }
}

internal func optionError(code: api.NetworkErrorCode, phase: api.NetworkPhase): api.NetworkException {
    api.NetworkException(api.NetworkErrorCategory.Option, phase, code,
        "socket option is unavailable for this operation", retryability: api.Retryability.Never)
}

internal func validateOptionName(
    name: StdSocketOptionName, target: StdSocketOptionTarget, ipv6: Bool,
    creation: Bool, query: Bool, phase: api.NetworkPhase
): Unit {
    if (!socketOptionsQualified()) { throw optionError(api.NetworkErrorCode.Unsupported, phase) }
    let index = optionIndex(name)
    let supported = match (target) {
        case StdSocketOptionTarget.Listener => index == 0 || index == 1 || index == 5 || index == 6 || index == 8
        case StdSocketOptionTarget.Tcp => index == 2 || index == 3 || index == 5 || index == 6
        case StdSocketOptionTarget.Udp => index != 2 && index != 3
    }
    if (!supported || (index == 8 && !ipv6) || (index == 4 && ipv6) ||
        (index == 7 && ipv6) || (index == 10 && !ipv6) ||
        (index == 9 && query && !ipv6)) {
        throw optionError(api.NetworkErrorCode.Unsupported, phase)
    }
    let udpPrebindMismatch = match (target) {
        case StdSocketOptionTarget.Udp => creation && !(index == 0 || index == 1 || index == 5 || index == 6 || index == 8)
        case _ => false
    }
    if (udpPrebindMismatch) { throw optionError(api.NetworkErrorCode.InvalidState, phase) }
    if (!creation && !query && (index == 0 || index == 1 || index == 8)) {
        throw optionError(api.NetworkErrorCode.InvalidState, phase)
    }
}

/** Validates a whole caller list before a factory allocates its socket. */
public func validateSocketOptions(
    options: Array<StdSocketOption>, target: StdSocketOptionTarget, ipv6: Bool,
    creation: Bool, phase: api.NetworkPhase
): Unit {
    validateSocketOptionsForPlatform(options, target, ipv6, creation, phase, socketOptionsQualified())
}

internal func validateSocketOptionsForPlatform(
    options: Array<StdSocketOption>, target: StdSocketOptionTarget, ipv6: Bool,
    creation: Bool, phase: api.NetworkPhase, platformQualified: Bool
): Unit {
    if (!platformQualified && options.size > 0) {
        throw optionError(api.NetworkErrorCode.Unsupported, phase)
    }
    if (options.size > 12) { throw IllegalArgumentException("at most twelve socket options are permitted") }
    var seen: UInt16 = 0
    for (option in options) {
        let index = optionIndex(option.name)
        let bit = 1u16 << UInt64(index)
        if ((seen & bit) != 0) { throw IllegalArgumentException("duplicate socket option") }
        seen = seen | bit
        let minimum: Int64 = if (index == 5 || index == 6) { 1 } else { 0 }
        let maximum: Int64 = if (index == 5 || index == 6 || index == 9) {
            2147483647
        } else if (index == 7 || index == 10) { 255 } else { 1 }
        if (option.value < minimum || option.value > maximum) {
            throw IllegalArgumentException("socket option value is outside its supported domain")
        }
        validateOptionName(option.name, target, ipv6, creation, false, phase)
    }
}

internal enum NativeOptionSocket {
    | Tcp(native.TcpSocket)
    | Listener(native.TcpServerSocket)
    | Udp(native.UdpSocket)
}

@C
private struct Ipv4MulticastInterface {
    var group: UInt32 = 0
    var address: UInt32 = 0
    var index: Int32 = 0
}

private func optionCoordinates(name: StdSocketOptionName, ipv6: Bool): (Int32, Int32) {
    match (name) {
        case StdSocketOptionName.ReuseAddress => (1, 2)
        case StdSocketOptionName.ReusePort => (1, 15)
        case StdSocketOptionName.NoDelay => (6, 1)
        case StdSocketOptionName.KeepAlive => (1, 9)
        case StdSocketOptionName.Broadcast => (1, 6)
        case StdSocketOptionName.ReceiveBuffer => (1, 8)
        case StdSocketOptionName.SendBuffer => (1, 7)
        case StdSocketOptionName.MulticastTtl => (0, 33)
        case StdSocketOptionName.Ipv6Only => (41, 26)
        case StdSocketOptionName.MulticastInterface => if (ipv6) { (41, 17) } else { (0, 32) }
        case StdSocketOptionName.MulticastHopLimit => (41, 18)
        case StdSocketOptionName.MulticastLoopback => if (ipv6) { (41, 19) } else { (0, 34) }
    }
}

private func setNativeOption(
    socket: NativeOptionSocket, level: Int32, name: Int32, value: CPointer<Unit>, size: UIntNative
): Unit {
    match (socket) {
        case NativeOptionSocket.Tcp(tcp) => tcp.setSocketOption(level, name, value, size)
        case NativeOptionSocket.Listener(listener) => listener.setSocketOption(level, name, value, size)
        case NativeOptionSocket.Udp(udp) => udp.setSocketOption(level, name, value, size)
    }
}

internal func applyNativeOption(socket: NativeOptionSocket, option: StdSocketOption, ipv6: Bool): Unit {
    match ((socket, option.name)) {
        case (NativeOptionSocket.Tcp(tcp), StdSocketOptionName.KeepAlive) =>
            tcp.keepAlive = if (option.value == 0) { None<native.SocketKeepAliveConfig> }
                else { Some(native.SocketKeepAliveConfig()) }
            return
        case (_, StdSocketOptionName.MulticastInterface) =>
            if (!ipv6) {
                let pointer = LibC.malloc<Ipv4MulticastInterface>()
                if (pointer.isNull()) { throw IllegalMemoryException("socket option allocation failed") }
                try {
                    var value = Ipv4MulticastInterface()
                    value.index = Int32(option.value)
                    unsafe { pointer.write(value) }
                    setNativeOption(socket, 0, 32, CPointer<Unit>(pointer), 12)
                } finally { unsafe { LibC.free(pointer) } }
                return
            }
        case _ => ()
    }
    let pointer = LibC.malloc<Int32>()
    if (pointer.isNull()) { throw IllegalMemoryException("socket option allocation failed") }
    try {
        unsafe { pointer.write(Int32(option.value)) }
        let (level, name) = optionCoordinates(option.name, ipv6)
        setNativeOption(socket, level, name, CPointer<Unit>(pointer), 4)
    } finally { unsafe { LibC.free(pointer) } }
}

internal func queryNativeOption(socket: NativeOptionSocket, name: StdSocketOptionName, ipv6: Bool): StdSocketOption {
    let pointer = LibC.malloc<Int32>()
    if (pointer.isNull()) { throw IllegalMemoryException("socket option allocation failed") }
    try {
        let size = LibC.malloc<UIntNative>()
        if (size.isNull()) { throw IllegalMemoryException("socket option length allocation failed") }
        try {
            unsafe { pointer.write(0); size.write(4) }
            let (level, nativeName) = optionCoordinates(name, ipv6)
            match (socket) {
                case NativeOptionSocket.Tcp(tcp) => tcp.getSocketOption(level, nativeName, CPointer<Unit>(pointer), size)
                case NativeOptionSocket.Listener(listener) => listener.getSocketOption(level, nativeName, CPointer<Unit>(pointer), size)
                case NativeOptionSocket.Udp(udp) => udp.getSocketOption(level, nativeName, CPointer<Unit>(pointer), size)
            }
            unsafe {
                if (size.read() != 4) {
                    let phase = match (socket) {
                        case NativeOptionSocket.Listener(_) => api.NetworkPhase.ServerAccept
                        case NativeOptionSocket.Tcp(_) => api.NetworkPhase.TcpConnect
                        case NativeOptionSocket.Udp(_) => api.NetworkPhase.DatagramSend
                    }
                    throw api.NetworkException(api.NetworkErrorCategory.Option, phase, api.NetworkErrorCode.SystemFailure,
                        "unexpected native socket option size", retryability: api.Retryability.Unknown)
                }
                StdSocketOption(name, Int64(pointer.read()))
            }
        } finally { unsafe { LibC.free(size) } }
    } finally { unsafe { LibC.free(pointer) } }
}

private func executeSocketOption(option: StdSocketOption, context: api.OperationContext,
    phase: api.NetworkPhase, execute: (StdSocketOption) -> Unit): Unit {
    checkNetworkContext(context, api.NetworkErrorCategory.Option, phase)
    try { execute(option) }
    catch (error: native.SocketException) {
        if (context.isCancellationRequested()) {
            throw networkCancelled(api.NetworkErrorCategory.Option, phase, cause: Some(error))
        }
        if (context.isDeadlineExceeded()) {
            throw networkDeadlineExceeded(api.NetworkErrorCategory.Option, phase, cause: Some(error))
        }
        throw api.NetworkException(api.NetworkErrorCategory.Option, phase, api.NetworkErrorCode.SystemFailure,
            "native socket option application failed", retryability: api.Retryability.Unknown, cause: Some(error))
    }
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func socketOptionsQualifiedImpl(): Bool { true }

@When[os != "Linux" || arch != "x86_64" || env != "gnu"]
private func socketOptionsQualifiedImpl(): Bool { false }

/** Provider SPI: whether this build target has native socket-option qualification. */
public func socketOptionsQualified(): Bool { socketOptionsQualifiedImpl() }

/** Executes defaults not overridden by the caller, followed by caller order. */
internal func applySocketOptionList(
    options: Array<StdSocketOption>, target: StdSocketOptionTarget,
    context: api.OperationContext, phase: api.NetworkPhase, defaults: Bool,
    execute: (StdSocketOption) -> Unit
): Unit {
    applySocketOptionListForPlatform(options, target, context, phase, defaults, socketOptionsQualified(), execute)
}

internal func applySocketOptionListForPlatform(
    options: Array<StdSocketOption>, target: StdSocketOptionTarget,
    context: api.OperationContext, phase: api.NetworkPhase, defaults: Bool,
    platformQualified: Bool, execute: (StdSocketOption) -> Unit
): Unit {
    if (defaults && platformQualified) {
        var seen: UInt16 = 0
        for (option in options) { seen = seen | (1u16 << UInt64(optionIndex(option.name))) }
        let requested: UInt16 = match (target) {
            case StdSocketOptionTarget.Listener => 1u16
            case StdSocketOptionTarget.Tcp => 12u16
            case StdSocketOptionTarget.Udp => 0u16
        }
        let missing = requested ^ (requested & seen)
        let reuseAddress = (missing & 1u16) != 0
        let noDelay = (missing & 4u16) != 0
        let keepAlive = (missing & 8u16) != 0
        let count = options.size + (if (reuseAddress) { 1 } else { 0 }) +
            (if (noDelay) { 1 } else { 0 }) + (if (keepAlive) { 1 } else { 0 })
        if (count > 12) { throw IllegalArgumentException("merged socket options exceed twelve entries") }
        if (reuseAddress) { executeSocketOption(StdSocketOption(StdSocketOptionName.ReuseAddress, 1), context, phase, execute) }
        if (noDelay) { executeSocketOption(StdSocketOption(StdSocketOptionName.NoDelay, 1), context, phase, execute) }
        if (keepAlive) { executeSocketOption(StdSocketOption(StdSocketOptionName.KeepAlive, 0), context, phase, execute) }
    }
    for (option in options) {
        executeSocketOption(option, context, phase, execute)
    }
}
