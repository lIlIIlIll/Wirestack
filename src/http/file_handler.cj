package wirestack.http

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
import std.sync.Mutex
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
import wirestack.internal.http_files as files

/** Explicit FileHandler operation mode. Download paths are relative to the configured root. */
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
public enum FileHandlerMode {
    /** Serves one validated root-relative path and rejects absolute paths, traversal components, and non-GET requests. */
    | Download(String)
    /** Accepts one safe filename-bearing multipart part, discards other parts, and rejects non-POST requests. */
    | Upload
}

/** Stable failures that must propagate through request cancellation rather than become HTTP status pages. */
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
public enum FileHandlerErrorCode {
    /** The shared operation context requested cancellation. */
    | Cancelled
    /** The shared operation context deadline expired. */
    | DeadlineExceeded
}

/** A FileHandler operation stopped by its shared OperationContext. */
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
public class FileHandlerException <: Exception {
    /** Stable cancellation or deadline category. */
    public let code: FileHandlerErrorCode
    /** Underlying multipart or filesystem failure that stopped the operation. */
    public let cause: ?Exception
    /**
     * Creates a file-handler context failure.
     * @param code Stable cancellation or deadline category.
     * @param message Diagnostic text.
     * @param cause Optional underlying multipart or filesystem failure.
     */
    public init(code: FileHandlerErrorCode, message: String,
        cause!: ?Exception = None<Exception>) {
        super(message)
        this.code = code
        this.cause = cause
    }

    /** Returns the stable exception class name. */
    protected override func getClassName(): String { "FileHandlerException" }
}

/**
 * Bounded file download or upload handler for Linux x86_64 GNU targets.
 *
 * The handler opens the trusted root directory during construction without following its final
 * symlink. It resolves each request path component beneath that directory without following
 * symlinks. Uploads write to a staging file and reject an existing destination.
 * The handler checks cancellation and deadlines between bounded synchronous filesystem calls.
 * A filesystem call already running in the kernel continues until that call returns.
 */
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
public class FileHandler <: HttpServerHandler & Resource {
    private let root: files.HttpFilesRoot
    private let mode: FileHandlerMode
    private let maximumBytes: Int64
    private let bufferSize: Int64
    private let validator: (String) -> Bool
    private let multipartLimits: MultipartLimits
    private let mutex = Mutex()
    private var closed = false

    /**
     * Opens a trusted root directory and creates a download or upload handler.
     * Upload parsing caps the complete multipart body at maximumBytes plus
     * maximumHeaderBytes times maximumParts plus 4096 bytes.
     * @param root Local directory path opened during construction; 1 through 4096 bytes with no NUL byte.
     * @param mode Fixed operation mode used for every request.
     * @param maximumBytes Maximum download file size or uploaded file payload bytes; must be nonnegative.
     * @param bufferSize Upload copy and multipart source-read buffer size, from 4096 through 1048576 bytes.
     * @param validator Filename policy that receives a safe basename; return true to accept it.
     * @param maximumParts Maximum multipart parts accepted by uploads, from 1 through 4096.
     * @param maximumHeaderBytes Maximum header-block bytes per upload part, from 1 through 1048576.
     */
    public init(
        root: String,
        mode: FileHandlerMode,
        maximumBytes!: Int64 = 1024 * 1024 * 1024,
        bufferSize!: Int64 = 64 * 1024,
        validator!: (String) -> Bool = { _ => true },
        maximumParts!: Int64 = 128,
        maximumHeaderBytes!: Int64 = 64 * 1024
    ) {
        if (root.isEmpty() || root.contains("\0") || maximumBytes < 0 ||
            bufferSize < 4096 || bufferSize > 1024 * 1024) {
            throw IllegalArgumentException("file handler root or limits are invalid")
        }
        match (mode) {
            case FileHandlerMode.Download(relativePath) =>
                validateDownloadRelativePath(relativePath)
            case FileHandlerMode.Upload => ()
        }
        let aggregateLimit = checkedFileAggregateLimit(
            maximumBytes, maximumHeaderBytes, maximumParts)
        let parsedMultipartLimits = MultipartLimits(
            maximumParts: maximumParts,
            maximumHeaderBytes: maximumHeaderBytes,
            maximumPartBytes: maximumBytes,
            maximumBodyBytes: aggregateLimit,
            readBufferBytes: bufferSize
        )
        let openedRoot = files.HttpFilesRoot(root)
        this.root = openedRoot
        this.mode = mode
        this.maximumBytes = maximumBytes
        this.bufferSize = bufferSize
        this.validator = validator
        this.multipartLimits = parsedMultipartLimits
    }

    /**
     * Opens a trusted root directory and creates a fixed-path download handler.
     * @param root Local directory path opened during construction; 1 through 4096 bytes with no NUL byte.
     * @param relativePath Slash-separated path of 1 through 4096 bytes beneath root. Empty or absolute paths, single-dot or double-dot components, empty components, control bytes, and backslashes are rejected.
     * @param maximumBytes Maximum regular-file size accepted for download; must be nonnegative.
     * @param bufferSize Buffer-size setting validated from 4096 through 1048576 bytes. It does not control download response reads.
     * @return A handler that accepts GET requests.
     */
    public static func download(root: String, relativePath: String,
        maximumBytes!: Int64 = 1024 * 1024 * 1024,
        bufferSize!: Int64 = 64 * 1024): FileHandler {
        FileHandler(root, FileHandlerMode.Download(relativePath),
            maximumBytes: maximumBytes, bufferSize: bufferSize)
    }

    /**
     * Opens a trusted root directory and creates a multipart upload handler.
     * The complete multipart body is limited to maximumBytes plus
     * maximumHeaderBytes times maximumParts plus 4096 bytes.
     * The filename must be a 1-through-1024-byte basename. Slash, backslash, NUL, control bytes,
     * single dot, and double dot are rejected before the validator runs.
     * @param root Local directory path opened during construction; 1 through 4096 bytes with no NUL byte.
     * @param maximumBytes Maximum bytes written from the single file part; must be nonnegative.
     * @param bufferSize Multipart source-read and file-copy buffer size, from 4096 through 1048576 bytes.
     * @param validator Filename policy that receives a safe basename; return true to accept it.
     * @param maximumParts Maximum multipart parts accepted, from 1 through 4096.
     * @param maximumHeaderBytes Maximum header-block bytes per part, from 1 through 1048576.
     * @return A handler that accepts POST requests containing exactly one filename-bearing part.
     */
    public static func upload(root: String,
        maximumBytes!: Int64 = 1024 * 1024 * 1024,
        bufferSize!: Int64 = 64 * 1024,
        validator!: (String) -> Bool = { _ => true },
        maximumParts!: Int64 = 128,
        maximumHeaderBytes!: Int64 = 64 * 1024): FileHandler {
        FileHandler(root, FileHandlerMode.Upload,
            maximumBytes: maximumBytes,
            bufferSize: bufferSize,
            validator: validator,
            maximumParts: maximumParts,
            maximumHeaderBytes: maximumHeaderBytes)
    }

    /**
     * Handles one request in the configured mode and takes responsibility for closing its body.
     * Downloads return a streaming application/octet-stream response. Uploads stream the file part
     * to a staging file, discard parts without filenames, and reject multiple filename-bearing parts.
     * Successful downloads return 200 with a streaming body and Content-Length.
     * Successful uploads return an empty 201 response. Cancellation and deadline failures propagate
     * as FileHandlerException.
     * @param request Incoming request. The handler closes or consumes its body on every path.
     * @param context Cancellation and deadline checked around multipart reads and filesystem calls.
     * @return A success response or an empty HTTP error response.
     */
    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        if (synchronized(mutex) { closed }) {
            request.body.close()
            return fileStatus(503, "Service Unavailable")
        }
        match (mode) {
            case FileHandlerMode.Download(relativePath) => handleDownload(request, context, relativePath)
            case FileHandlerMode.Upload => handleUpload(request, context)
        }
    }

    /** Closes the root directory and makes later requests return 503. Existing response streams keep their own file handles. */
    public func close(): Unit {
        synchronized(mutex) {
            if (!closed) {
                closed = true
                root.close()
            }
        }
    }

    /** Reports whether close has closed the handler's root directory. */
    public func isClosed(): Bool { synchronized(mutex) { closed } }

    private func handleDownload(request: HttpServerRequest, context: OperationContext,
        relativePath: String): HttpServerResponse {
        if (request.method != HttpMethod("GET")) {
            request.body.close()
            return fileStatus(405, "Method Not Allowed", allow: Some("GET"))
        }
        request.body.close()
        try {
            let stream = root.openRead(relativePath, maximumBytes, context)
            let length = stream.contentLength.getOrThrow()
            let headers = HttpHeaders.builder()
                .add("Content-Type", "application/octet-stream")
                .add("Content-Length", "${length}")
                .add("X-Content-Type-Options", "nosniff")
                .build()
            HttpServerResponse(HttpResponse(
                200,
                "OK",
                ResponseBody(stream),
                headers: headers
            ))
        } catch (error: files.HttpFilesException) {
            mapFileFailure(error)
        }
    }

    private func handleUpload(request: HttpServerRequest,
        context: OperationContext): HttpServerResponse {
        if (request.method != HttpMethod("POST")) {
            request.body.close()
            return fileStatus(405, "Method Not Allowed", allow: Some("POST"))
        }
        var reader: ?MultipartReader = None<MultipartReader>
        var upload: ?files.NativeUpload = None<files.NativeUpload>
        try {
            let opened = MultipartReader.fromRequest(request, limits: multipartLimits, context: context)
            reader = Some(opened)
            var uploadedFilename: ?String = None<String>
            while (true) {
                match (opened.next()) {
                    case Some(part) =>
                        try {
                            match (part.filename) {
                                case Some(filename) =>
                                    if (uploadedFilename.isSome()) {
                                        throw MultipartException(MultipartErrorCode.InvalidMetadata,
                                            "file upload accepts exactly one file part")
                                    }
                                    validateUploadFilename(filename)
                                    if (!validator(filename)) {
                                        throw MultipartException(MultipartErrorCode.InvalidMetadata,
                                            "uploaded filename was rejected by policy")
                                    }
                                    let staging = root.beginUpload(filename, maximumBytes, context)
                                    upload = Some(staging)
                                    let buffer = Array<Byte>(bufferSize, repeat: 0u8)
                                    while (true) {
                                        let count = part.body.read(buffer)
                                        if (count == 0) { break }
                                        staging.write(buffer, count)
                                    }
                                    uploadedFilename = Some(filename)
                                case None =>
                                    part.close()
                            }
                        } finally {
                            part.close()
                        }
                    case None => break
                }
            }
            let staging = upload.getOrThrow({ => MultipartException(
                MultipartErrorCode.InvalidMetadata,
                "file upload requires one multipart part with a filename"
            ) })
            staging.commit()
            upload = None<files.NativeUpload>
            fileStatus(201, "Created")
        } catch (error: MultipartException) {
            mapMultipartFailure(error, context)
        } catch (error: files.HttpFilesException) {
            mapFileFailure(error)
        } catch (_: Exception) {
            fileStatus(500, "Internal Server Error")
        } finally {
            if (let Some(staging) <- upload) { staging.abort() }
            match (reader) {
                case Some(opened) => opened.close()
                case None => request.body.close()
            }
        }
    }
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func mapMultipartFailure(error: MultipartException,
    context: OperationContext): HttpServerResponse {
    match (error.code) {
        case MultipartErrorCode.PartLimitExceeded |
            MultipartErrorCode.HeaderLimitExceeded |
            MultipartErrorCode.PartBytesLimitExceeded |
            MultipartErrorCode.BodyBytesLimitExceeded => fileStatus(413, "Payload Too Large")
        case MultipartErrorCode.ContextStopped =>
            if (context.isCancellationRequested()) {
                throw FileHandlerException(FileHandlerErrorCode.Cancelled,
                    "file upload operation was cancelled", cause: Some(error))
            }
            throw FileHandlerException(FileHandlerErrorCode.DeadlineExceeded,
                "file upload operation deadline exceeded", cause: Some(error))
        case _ => fileStatus(400, "Bad Request")
    }
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func mapFileFailure(error: files.HttpFilesException): HttpServerResponse {
    match (error.status) {
        case files.HttpFilesStatus.NotFound => fileStatus(404, "Not Found")
        case files.HttpFilesStatus.AlreadyExists => fileStatus(409, "Conflict")
        case files.HttpFilesStatus.LimitExceeded => fileStatus(413, "Payload Too Large")
        case files.HttpFilesStatus.InvalidArgument |
            files.HttpFilesStatus.SymlinkRejected |
            files.HttpFilesStatus.Nonregular => fileStatus(400, "Bad Request")
        case files.HttpFilesStatus.PermissionDenied => fileStatus(403, "Forbidden")
        case files.HttpFilesStatus.Cancelled =>
            throw FileHandlerException(FileHandlerErrorCode.Cancelled,
                "file operation was cancelled", cause: Some(error))
        case files.HttpFilesStatus.DeadlineExceeded =>
            throw FileHandlerException(FileHandlerErrorCode.DeadlineExceeded,
                "file operation deadline exceeded", cause: Some(error))
        case _ => fileStatus(500, "Internal Server Error")
    }
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func fileStatus(status: Int64, reason: String,
    allow!: ?String = None<String>): HttpServerResponse {
    let builder = HttpHeaders.builder().add("Content-Length", "0")
    if (let Some(value) <- allow) { let _ = builder.add("Allow", value) }
    HttpServerResponse(HttpResponse(
        status,
        reason,
        ResponseBody.empty(),
        headers: builder.build()
    ))
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func validateDownloadRelativePath(value: String): Unit {
    let bytes = value.toArray()
    if (bytes.isEmpty() || bytes.size > 4096 || bytes[0] == b'/' || value.contains("\0") ||
        value.contains("\\")) {
        throw IllegalArgumentException("download path is not a safe relative path")
    }
    var componentStart: Int64 = 0
    var index: Int64 = 0
    while (index <= bytes.size) {
        if (index == bytes.size || bytes[index] == b'/') {
            validatePathComponent(bytes, componentStart, index)
            componentStart = index + 1
        }
        index += 1
    }
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func validateUploadFilename(value: String): Unit {
    let bytes = value.toArray()
    if (bytes.isEmpty() || bytes.size > 1024 || value.contains("\0") ||
        value.contains("/") || value.contains("\\")) {
        throw MultipartException(MultipartErrorCode.InvalidMetadata,
            "uploaded filename is not a safe root-relative basename")
    }
    try {
        validatePathComponent(bytes, 0, bytes.size)
    } catch (_: IllegalArgumentException) {
        throw MultipartException(MultipartErrorCode.InvalidMetadata,
            "uploaded filename is not a safe root-relative basename")
    }
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func validatePathComponent(bytes: Array<Byte>, start: Int64, end: Int64): Unit {
    if (start == end || (end - start == 1 && bytes[start] == b'.') ||
        (end - start == 2 && bytes[start] == b'.' && bytes[start + 1] == b'.')) {
        throw IllegalArgumentException("file path contains an unsafe component")
    }
    for (index in start..end) {
        if (bytes[index] < 0x20u8 || bytes[index] == 0x7fu8) {
            throw IllegalArgumentException("file path contains a control byte")
        }
    }
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func checkedFileAggregateLimit(maximumBytes: Int64,
    maximumHeaderBytes: Int64, maximumParts: Int64): Int64 {
    if (maximumParts <= 0 || maximumParts > 4096 || maximumHeaderBytes <= 0 ||
        maximumHeaderBytes > 1024 * 1024) {
        throw IllegalArgumentException("file upload multipart limits are invalid")
    }
    if (maximumHeaderBytes > Int64.Max / maximumParts) {
        throw IllegalArgumentException("file upload multipart aggregate limit overflows")
    }
    let metadata = maximumHeaderBytes * maximumParts
    if (metadata > Int64.Max - 4096 ||
        maximumBytes > Int64.Max - metadata - 4096) {
        throw IllegalArgumentException("file upload multipart aggregate limit overflows")
    }
    maximumBytes + metadata + 4096
}
