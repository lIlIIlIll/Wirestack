package wirestack.http

import std.fs.*
import std.sync.Mutex

public enum BodyReplayability <: Equatable<BodyReplayability> {
    | Replayable
    | OneShot

    public operator func ==(other: BodyReplayability): Bool {
        match ((this, other)) {
            case (BodyReplayability.Replayable, BodyReplayability.Replayable) => true
            case (BodyReplayability.OneShot, BodyReplayability.OneShot) => true
            case _ => false
        }
    }

    public operator func !=(other: BodyReplayability): Bool { !(this == other) }
}

public enum HttpBodyErrorCode {
    | Closed
    | ConcurrentRead
    | AlreadyOpened
    | InvalidLength
    | InvalidFile
    | FileChanged
    | PrematureEof
    | FactoryContractViolation
}

public class HttpBodyException <: Exception {
    public let code: HttpBodyErrorCode
    public let cause: ?Exception

    public init(code: HttpBodyErrorCode, message: String, cause!: ?Exception = None<Exception>) {
        super(message)
        this.code = code
        this.cause = cause
    }

    protected override func getClassName(): String { "HttpBodyException" }
}

/** Pull-based stream. A zero result means EOF unless the destination is empty. */
public interface HttpBodyStream <: Resource {
    prop contentLength: ?Int64
    func read(destination: Array<Byte>): Int64
}

/** Immutable request-body source supporting replayable and one-shot ownership. */
public class RequestBody {
    public let contentLength: ?Int64
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

    public static func empty(): RequestBody {
        RequestBody(Some(0), BodyReplayability.Replayable, { => ByteArrayBodyStream(Array<Byte>()) })
    }

    public static func bytes(value: Array<Byte>): RequestBody {
        let owned = value.clone()
        RequestBody(Some(owned.size), BodyReplayability.Replayable, { => ByteArrayBodyStream(owned) })
    }

    public static func string(value: String): RequestBody {
        RequestBody.bytes(value.toArray())
    }

    /** Opens a fresh bounded regular file for every replay. The file is never read eagerly. */
    public static func file(path: String, maximumBytes!: Int64 = 1073741824): RequestBody {
        if (path.isEmpty() || path.contains("\0") || maximumBytes < 0) { invalidFile() }
        let expected = inspectBodyFile(path, maximumBytes)
        RequestBody(
            Some(expected),
            BodyReplayability.Replayable,
            { => FileBodyStream(path, expected) }
        )
    }

    public static func replayableFactory(
        contentLength: ?Int64,
        factory: () -> HttpBodyStream
    ): RequestBody {
        RequestBody(contentLength, BodyReplayability.Replayable, factory)
    }

    public static func oneShot(stream: HttpBodyStream): RequestBody {
        RequestBody(stream.contentLength, BodyReplayability.OneShot, { => stream })
    }

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

    public prop contentLength: ?Int64 { get() { Some(bytes.size) } }

    public func read(destination: Array<Byte>): Int64 {
        ensureBodyOpen(closed)
        if (destination.isEmpty() || offset == bytes.size) { return 0 }
        let count = min(destination.size, bytes.size - offset)
        for (index in 0..count) { destination[index] = bytes[offset + index] }
        offset += count
        count
    }

    public func close(): Unit { closed = true }
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

    public prop contentLength: ?Int64 { get() { Some(expectedLength) } }

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

    public func close(): Unit {
        if (!closed) { closed = true; file.close() }
    }

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
