package wirestack

import std.fs.*
import std.sync.Mutex

/**
 * Wirestack 公开 API：BodyReplayability。
 */
public enum BodyReplayability <: Equatable<BodyReplayability> {
/**
 * Wirestack 公开 API：Replayable。
 */
    | Replayable
/**
 * Wirestack 公开 API：OneShot。
 */
    | OneShot

/**
 * Wirestack 公开 API：==。
 * @param other 参数 other。
 */
    public operator func ==(other: BodyReplayability): Bool {
        match ((this, other)) {
            case (BodyReplayability.Replayable, BodyReplayability.Replayable) => true
            case (BodyReplayability.OneShot, BodyReplayability.OneShot) => true
            case _ => false
        }
    }

/**
 * Wirestack 公开 API：!=。
 * @param other 参数 other。
 */
    public operator func !=(other: BodyReplayability): Bool { !(this == other) }
}

/**
 * Wirestack 公开 API：HttpBodyErrorCode。
 */
public enum HttpBodyErrorCode {
/**
 * Wirestack 公开 API：Closed。
 */
    | Closed
/**
 * Wirestack 公开 API：ConcurrentRead。
 */
    | ConcurrentRead
/**
 * Wirestack 公开 API：AlreadyOpened。
 */
    | AlreadyOpened
/**
 * Wirestack 公开 API：InvalidLength。
 */
    | InvalidLength
/**
 * Wirestack 公开 API：InvalidFile。
 */
    | InvalidFile
/**
 * Wirestack 公开 API：FileChanged。
 */
    | FileChanged
/**
 * Wirestack 公开 API：PrematureEof。
 */
    | PrematureEof
/**
 * Wirestack 公开 API：FactoryContractViolation。
 */
    | FactoryContractViolation
/**
 * Wirestack 公开 API：InvalidProgress。
 */
    | InvalidProgress
}

/**
 * Wirestack 公开 API：HttpBodyException。
 */
public class HttpBodyException <: Exception {
/**
 * Wirestack 公开 API：code。
 */
    public let code: HttpBodyErrorCode
/**
 * Wirestack 公开 API：cause。
 */
    public let cause: ?Exception

/**
 * Wirestack 公开 API：init。
 * @param cause 参数 cause。
 * @param code 参数 code。
 * @param message 参数 message。
 */
    public init(code: HttpBodyErrorCode, message: String, cause!: ?Exception = None<Exception>) {
        super(message)
        this.code = code
        this.cause = cause
    }

/**
 * Wirestack 公开 API：getClassName。
 */
    protected override func getClassName(): String { "HttpBodyException" }
}

/** Pull-based stream. A zero result means EOF unless the destination is empty. */
public interface HttpBodyStream <: Resource {
/**
 * Wirestack 公开 API：contentLength。
 */
    prop contentLength: ?Int64
/**
 * Wirestack 公开 API：read。
 * @param destination 参数 destination。
 */
    func read(destination: Array<Byte>): Int64
}

/** Immutable request-body source supporting replayable and one-shot ownership. */
public class RequestBody {
/**
 * Wirestack 公开 API：contentLength。
 */
    public let contentLength: ?Int64
/**
 * Wirestack 公开 API：replayability。
 */
    public let replayability: BodyReplayability
    private let factory: () -> HttpBodyStream
    private let openMutex = Mutex()
    private var opened = false

    private init(
        contentLength: ?Int64,
        replayability: BodyReplayability,
        factory: () -> HttpBodyStream
    ) {
        validateDeclaredLength(contentLength)
        this.contentLength = contentLength
        this.replayability = replayability
        this.factory = factory
    }

/**
 * Wirestack 公开 API：empty。
 */
    public static func empty(): RequestBody {
        RequestBody(Some(0), BodyReplayability.Replayable, { => ByteArrayBodyStream(Array<Byte>()) })
    }

/**
 * Wirestack 公开 API：bytes。
 * @param value 参数 value。
 */
    public static func bytes(value: Array<Byte>): RequestBody {
        let owned = value.clone()
        RequestBody(Some(owned.size), BodyReplayability.Replayable, { => ByteArrayBodyStream(owned) })
    }

/**
 * Wirestack 公开 API：string。
 * @param value 参数 value。
 */
    public static func string(value: String): RequestBody {
        RequestBody.bytes(value.toArray())
    }

/**
 * Opens a fresh bounded regular file for every replay. The file is never read eagerly.
 * @param maximumBytes 参数 maximumBytes。
 * @param path 参数 path。
 */
    public static func file(path: String, maximumBytes!: Int64 = 1073741824): RequestBody {
        if (path.isEmpty() || path.contains("\0") || maximumBytes < 0) { invalidFile() }
        let expected = inspectBodyFile(path, maximumBytes)
        RequestBody(
            Some(expected),
            BodyReplayability.Replayable,
            { => FileBodyStream(path, expected) }
        )
    }

/**
 * Wirestack 公开 API：replayableFactory。
 * @param contentLength 参数 contentLength。
 * @param factory 参数 factory。
 */
    public static func replayableFactory(
        contentLength: ?Int64,
        factory: () -> HttpBodyStream
    ): RequestBody {
        RequestBody(contentLength, BodyReplayability.Replayable, factory)
    }

/**
 * Wirestack 公开 API：oneShot。
 * @param stream 参数 stream。
 */
    public static func oneShot(stream: HttpBodyStream): RequestBody {
        RequestBody(stream.contentLength, BodyReplayability.OneShot, { => stream })
    }

/**
 * Wirestack 公开 API：open。
 */
    public func open(): HttpBodyStream {
        synchronized(openMutex) {
            if (replayability == BodyReplayability.OneShot && opened) {
                throw HttpBodyException(HttpBodyErrorCode.AlreadyOpened, "one-shot HTTP body has already been opened")
            }
            if (replayability == BodyReplayability.OneShot) { opened = true }
        }
        // A user-supplied factory may block or call arbitrary code. Never run it while
        // holding the ownership mutex; a claimed one-shot stays consumed if it throws.
        let stream = factory()
        if (stream.contentLength != contentLength) {
            try { stream.close() } catch (_: Exception) {}
            throw HttpBodyException(
                HttpBodyErrorCode.FactoryContractViolation,
                "HTTP body factory returned a stream with a different declared length"
            )
        }
        stream
    }
}

private class ByteArrayBodyStream <: HttpBodyStream {
    private let bytes: Array<Byte>
    private var offset: Int64 = 0
    private var closed = false

    init(bytes: Array<Byte>) { this.bytes = bytes }

/**
 * Wirestack 公开 API：contentLength。
 */
    public prop contentLength: ?Int64 { get() { Some(bytes.size) } }

/**
 * Wirestack 公开 API：read。
 * @param destination 参数 destination。
 */
    public func read(destination: Array<Byte>): Int64 {
        ensureBodyOpen(closed)
        if (destination.isEmpty() || offset == bytes.size) { return 0 }
        let count = min(destination.size, bytes.size - offset)
        for (index in 0..count) { destination[index] = bytes[offset + index] }
        offset += count
        count
    }

/**
 * Wirestack 公开 API：close。
 */
    public func close(): Unit { closed = true }
/**
 * Wirestack 公开 API：isClosed。
 */
    public func isClosed(): Bool { closed }
}

private class FileBodyStream <: HttpBodyStream {
    private let file: File
    private let expectedLength: Int64
    private var consumed: Int64 = 0
    private var closed = false

    init(path: String, expectedLength: Int64) {
        let opened = try {
            File(path, OpenMode.Read)
        } catch (error: Exception) {
            throw HttpBodyException(HttpBodyErrorCode.InvalidFile, "HTTP body file could not be opened", cause: error)
        }
        try {
            let info = opened.info
            if (!info.isRegular() || !opened.canRead() || opened.length != expectedLength) {
                throw HttpBodyException(HttpBodyErrorCode.FileChanged, "HTTP body file changed before it was opened")
            }
        } catch (error: Exception) {
            opened.close()
            throw error
        }
        file = opened
        this.expectedLength = expectedLength
    }

/**
 * Wirestack 公开 API：contentLength。
 */
    public prop contentLength: ?Int64 { get() { Some(expectedLength) } }

/**
 * Wirestack 公开 API：read。
 * @param destination 参数 destination。
 */
    public func read(destination: Array<Byte>): Int64 {
        ensureBodyOpen(closed)
        if (destination.isEmpty()) { return 0 }
        if (consumed == expectedLength) {
            if (file.length != expectedLength) {
                throw HttpBodyException(HttpBodyErrorCode.FileChanged, "HTTP body file changed while being read")
            }
            return 0
        }
        let requested = min(destination.size, expectedLength - consumed)
        let count = if (requested == destination.size) {
            file.read(destination)
        } else {
            let staging = Array<Byte>(requested, repeat: 0)
            let read = file.read(staging)
            for (index in 0..read) { destination[index] = staging[index] }
            read
        }
        if (count <= 0) {
            throw HttpBodyException(HttpBodyErrorCode.PrematureEof, "HTTP body file ended before its declared length")
        }
        if (count > requested) {
            throw HttpBodyException(HttpBodyErrorCode.FileChanged, "HTTP body file returned more than the bounded request")
        }
        consumed += count
        count
    }

/**
 * Wirestack 公开 API：close。
 */
    public func close(): Unit {
        if (!closed) { closed = true; file.close() }
    }

/**
 * Wirestack 公开 API：isClosed。
 */
    public func isClosed(): Bool { closed }
}

private func inspectBodyFile(path: String, maximumBytes: Int64): Int64 {
    try {
        let info = FileInfo(path)
        if (!info.isRegular() || !info.canRead() || info.size < 0 || info.size > maximumBytes) { invalidFile() }
        info.size
    } catch (error: HttpBodyException) {
        throw error
    } catch (error: Exception) {
        throw HttpBodyException(HttpBodyErrorCode.InvalidFile, "HTTP body file is not a readable bounded regular file", cause: error)
    }
}

private func validateDeclaredLength(length: ?Int64): Unit {
    if (let Some(value) <- length) {
        if (value < 0) {
            throw HttpBodyException(HttpBodyErrorCode.InvalidLength, "HTTP body length cannot be negative")
        }
    }
}

private func ensureBodyOpen(closed: Bool): Unit {
    if (closed) { throw HttpBodyException(HttpBodyErrorCode.Closed, "HTTP body stream is closed") }
}

private func invalidFile(): Nothing {
    throw HttpBodyException(HttpBodyErrorCode.InvalidFile, "HTTP body file is not a readable bounded regular file")
}
