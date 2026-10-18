package wirestack.gzip

import wirestack.*

/** Stable failure categories for the optional gzip body wrapper. */
public enum GzipErrorCode <: Equatable<GzipErrorCode> {
    /** Compressed bytes exceed the absolute input bound. */
    | InputLimit
    /** Decoded bytes exceed the absolute output bound. */
    | OutputLimit
    /** A gzip header exceeds its scan bound. */
    | HeaderLimit
    /** Concatenated members exceed the configured count. */
    | MemberLimit
    /** DEFLATE blocks exceed the configured count. */
    | BlockLimit
    /** The gzip identifier, method or reserved flags are invalid. */
    | InvalidHeader
    /** An invalid block, Huffman table or history reference is encountered. */
    | InvalidDeflate
    /** Header or payload CRC does not match. */
    | ChecksumMismatch
    /** Member ISIZE does not match decoded bytes. */
    | SizeMismatch
    /** Gzip framing or DEFLATE ends prematurely. */
    | UnexpectedEof
    /** Non-member bytes follow a completed gzip member. */
    | TrailingData
    /** The response coding is unknown or layered. */
    | UnsupportedCoding
    /** A reader overlaps another reader. */
    | ConcurrentOperation
    /** The decoded body was closed locally. */
    | Closed

    /** Compares failure categories.
     * @param other Category to compare.
     */
    public operator func ==(other: GzipErrorCode): Bool {
        match ((this, other)) {
            case (GzipErrorCode.InputLimit, GzipErrorCode.InputLimit) => true
            case (GzipErrorCode.OutputLimit, GzipErrorCode.OutputLimit) => true
            case (GzipErrorCode.HeaderLimit, GzipErrorCode.HeaderLimit) => true
            case (GzipErrorCode.MemberLimit, GzipErrorCode.MemberLimit) => true
            case (GzipErrorCode.BlockLimit, GzipErrorCode.BlockLimit) => true
            case (GzipErrorCode.InvalidHeader, GzipErrorCode.InvalidHeader) => true
            case (GzipErrorCode.InvalidDeflate, GzipErrorCode.InvalidDeflate) => true
            case (GzipErrorCode.ChecksumMismatch, GzipErrorCode.ChecksumMismatch) => true
            case (GzipErrorCode.SizeMismatch, GzipErrorCode.SizeMismatch) => true
            case (GzipErrorCode.UnexpectedEof, GzipErrorCode.UnexpectedEof) => true
            case (GzipErrorCode.TrailingData, GzipErrorCode.TrailingData) => true
            case (GzipErrorCode.UnsupportedCoding, GzipErrorCode.UnsupportedCoding) => true
            case (GzipErrorCode.ConcurrentOperation, GzipErrorCode.ConcurrentOperation) => true
            case (GzipErrorCode.Closed, GzipErrorCode.Closed) => true
            case _ => false
        }
    }
    /** Compares whether categories differ.
     * @param other Category to compare.
     */
    public operator func !=(other: GzipErrorCode): Bool { !(this == other) }
}

/** Integrity, format or configured-limit failure. Message text is not a control-flow contract. */
public class GzipException <: Exception {
    /** Stable gzip failure code. */
    public let code: GzipErrorCode
    /** Original underlying failure when present. */
    public let cause: ?Exception
    /** Decode failures belong to response-body processing. */
    public prop phase: NetworkPhase { get() { NetworkPhase.HttpBody } }
    /** Decoding never creates permission to replay a request. */
    public prop retryability: Retryability { get() { Retryability.Never } }
    /** Constructs a typed decode failure.
     * @param code Stable failure code.
     * @param message Diagnostic text.
     * @param cause Original failure.
     */
    public init(code: GzipErrorCode, message: String, cause!: ?Exception = None<Exception>) {
        super(message); this.code = code; this.cause = cause
    }
    /** Returns the diagnostic exception class name. */
    protected override func getClassName(): String { "GzipException" }
}

/** Absolute per-body bounds; a compression ratio cannot replace these limits. */
public class GzipLimits {
    /** Compressed bytes read, including header/trailer and read-ahead. */
    public let maximumEncodedBytes: Int64
    /** Cumulative output across all members. */
    public let maximumDecodedBytes: Int64
    /** Bytes scanned per gzip header, including optional fields. */
    public let maximumHeaderBytes: Int64
    /** Accepted gzip members; default rejects concatenation. */
    public let maximumMembers: Int64
    /** Cumulative DEFLATE blocks, including empty blocks. */
    public let maximumBlocks: Int64
    /** Maximum retained unread compressed input. */
    public let inputBufferBytes: Int64
    /** Maximum output delivered by one read call. */
    public let maximumReadBytes: Int64
    /** Conservative codec storage including the fixed 32 KiB history and bounded Huffman tables; excludes caller output. */
    public prop maximumRetainedBytes: UInt64 { get() { UInt64(128 * 1024 + inputBufferBytes) } }
    /** Checks positive policy values against fixed hard ceilings.
     * @param maximumEncodedBytes Input cap, at most 1 GiB.
     * @param maximumDecodedBytes Output cap, at most 1 GiB.
     * @param maximumHeaderBytes Header scan cap, at most 64 KiB.
     * @param maximumMembers Member count, at most 128.
     * @param maximumBlocks Block count, at most 65536.
     * @param inputBufferBytes Input buffer size, at most 64 KiB.
     * @param maximumReadBytes Per-read output, at most 64 KiB.
     */
    public init(maximumEncodedBytes!: Int64 = 64 * 1024 * 1024,
        maximumDecodedBytes!: Int64 = 64 * 1024 * 1024, maximumHeaderBytes!: Int64 = 4096,
        maximumMembers!: Int64 = 1, maximumBlocks!: Int64 = 4096,
        inputBufferBytes!: Int64 = 4096, maximumReadBytes!: Int64 = 16 * 1024) {
        if (maximumEncodedBytes < 1 || maximumEncodedBytes > 1073741824) { throw IllegalArgumentException("gzip maximumEncodedBytes is outside its hard bound") }
        this.maximumEncodedBytes = maximumEncodedBytes
        if (maximumDecodedBytes < 1 || maximumDecodedBytes > 1073741824) { throw IllegalArgumentException("gzip maximumDecodedBytes is outside its hard bound") }
        this.maximumDecodedBytes = maximumDecodedBytes
        if (maximumHeaderBytes < 1 || maximumHeaderBytes > 65536) { throw IllegalArgumentException("gzip maximumHeaderBytes is outside its hard bound") }
        this.maximumHeaderBytes = maximumHeaderBytes
        if (maximumMembers < 1 || maximumMembers > 128) { throw IllegalArgumentException("gzip maximumMembers is outside its hard bound") }
        this.maximumMembers = maximumMembers
        if (maximumBlocks < 1 || maximumBlocks > 65536) { throw IllegalArgumentException("gzip maximumBlocks is outside its hard bound") }
        this.maximumBlocks = maximumBlocks
        if (inputBufferBytes < 1 || inputBufferBytes > 65536) { throw IllegalArgumentException("gzip inputBufferBytes is outside its hard bound") }
        this.inputBufferBytes = inputBufferBytes
        if (maximumReadBytes < 1 || maximumReadBytes > 65536) { throw IllegalArgumentException("gzip maximumReadBytes is outside its hard bound") }
        this.maximumReadBytes = maximumReadBytes
    }
}

internal func checkGzipContext(context: OperationContext): Unit {
    if (context.isCancellationRequested()) {
        throw NetworkException(NetworkErrorCategory.Cancelled, NetworkPhase.HttpBody,
            NetworkErrorCode.Cancelled, "gzip decoding cancelled", retryability: Retryability.Never)
    }
    if (context.isDeadlineExceeded()) {
        throw NetworkException(NetworkErrorCategory.DeadlineExceeded, NetworkPhase.HttpBody,
            NetworkErrorCode.TimedOut, "gzip decoding deadline exceeded", retryability: Retryability.Temporary)
    }
}
