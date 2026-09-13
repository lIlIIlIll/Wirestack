package wirestack.internal.http_files

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
import std.sync.Mutex
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
import wirestack as api

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private let HTTP_FILES_OK: Int32 = 0
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private let HTTP_FILES_INVALID_ARGUMENT: Int32 = 1
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private let HTTP_FILES_OUT_OF_MEMORY: Int32 = 2
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private let HTTP_FILES_NOT_FOUND: Int32 = 3
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private let HTTP_FILES_PERMISSION_DENIED: Int32 = 4
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private let HTTP_FILES_SYMLINK_REJECTED: Int32 = 5
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private let HTTP_FILES_NONREGULAR: Int32 = 6
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private let HTTP_FILES_LIMIT_EXCEEDED: Int32 = 7
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private let HTTP_FILES_ALREADY_EXISTS: Int32 = 8
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private let HTTP_FILES_CLOSED: Int32 = 9
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private let HTTP_FILES_FILE_CHANGED: Int32 = 10

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
foreign func wirestack_http_files_abi_version(): UInt32
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
foreign func wirestack_http_files_root_open(
    path: CPointer<Byte>,
    pathSize: UInt64,
    outRootHandle: CPointer<UInt64>,
    outNativeCode: CPointer<Int64>
): Int32
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
foreign func wirestack_http_files_root_close(rootHandle: UInt64): Unit
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
foreign func wirestack_http_files_download_open(
    rootHandle: UInt64,
    relativePath: CPointer<Byte>,
    relativePathSize: UInt64,
    maximumBytes: UInt64,
    outFileHandle: CPointer<UInt64>,
    outFileSize: CPointer<UInt64>,
    outNativeCode: CPointer<Int64>
): Int32
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
foreign func wirestack_http_files_file_read(
    fileHandle: UInt64,
    output: CPointer<Byte>,
    outputCapacity: UInt64,
    outCount: CPointer<UInt64>,
    outNativeCode: CPointer<Int64>
): Int32
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
foreign func wirestack_http_files_file_close(fileHandle: UInt64): Unit
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
foreign func wirestack_http_files_upload_begin(
    rootHandle: UInt64,
    filename: CPointer<Byte>,
    filenameSize: UInt64,
    maximumBytes: UInt64,
    outUploadHandle: CPointer<UInt64>,
    outNativeCode: CPointer<Int64>
): Int32
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
foreign func wirestack_http_files_upload_write(
    uploadHandle: UInt64,
    input: CPointer<Byte>,
    inputSize: UInt64,
    outNativeCode: CPointer<Int64>
): Int32
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
foreign func wirestack_http_files_upload_commit(
    uploadHandle: UInt64,
    outNativeCode: CPointer<Int64>
): Int32
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
foreign func wirestack_http_files_upload_abort(uploadHandle: UInt64): Unit

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
public enum HttpFilesStatus {
    | InvalidArgument
    | OutOfMemory
    | NotFound
    | PermissionDenied
    | SymlinkRejected
    | Nonregular
    | LimitExceeded
    | AlreadyExists
    | Closed
    | FileChanged
    | Cancelled
    | DeadlineExceeded
    | SystemFailure
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
public class HttpFilesException <: Exception {
    public let status: HttpFilesStatus
    public let nativeCode: ?Int64

    public init(status: HttpFilesStatus, message: String, nativeCode!: ?Int64 = None<Int64>) {
        super(message)
        this.status = status
        this.nativeCode = nativeCode
    }

    protected override func getClassName(): String { "HttpFilesException" }
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
public class HttpFilesRoot <: Resource {
    private let mutex = Mutex()
    private var handle: UInt64 = 0u64
    private var closed = false

    public init(path: String) {
        if (unsafe { wirestack_http_files_abi_version() } != 1u32) {
            throw HttpFilesException(HttpFilesStatus.SystemFailure,
                "wirestack_http_files ABI version mismatch")
        }
        let bytes = path.toArray()
        if (bytes.isEmpty() || bytes.size > 4096 || path.contains("\0")) {
            throw HttpFilesException(HttpFilesStatus.InvalidArgument, "file root path is invalid")
        }
        let output = [0u64]
        let nativeCode = [0i64]
        let status = unsafe {
            let inputRaw = acquireArrayRawData(bytes)
            let outputRaw = acquireArrayRawData(output)
            let nativeRaw = acquireArrayRawData(nativeCode)
            try {
                wirestack_http_files_root_open(
                    inputRaw.pointer,
                    UInt64(bytes.size),
                    outputRaw.pointer,
                    nativeRaw.pointer
                )
            } finally {
                releaseArrayRawData(nativeRaw)
                releaseArrayRawData(outputRaw)
                releaseArrayRawData(inputRaw)
            }
        }
        if (status != HTTP_FILES_OK || output[0] == 0u64) {
            if (output[0] != 0u64) {
                unsafe { wirestack_http_files_root_close(output[0]) }
            }
            throwHttpFiles(status, nativeCode[0], "file root could not be opened")
        }
        handle = output[0]
    }

    public func openRead(relativePath: String, maximumBytes: Int64,
        context: api.OperationContext): NativeReadFile {
        if (maximumBytes < 0) {
            throw HttpFilesException(HttpFilesStatus.InvalidArgument, "download byte limit is invalid")
        }
        checkContext(context)
        let path = relativePath.toArray()
        if (path.isEmpty() || path.size > 4096 || relativePath.contains("\0")) {
            throw HttpFilesException(HttpFilesStatus.InvalidArgument, "download relative path is invalid")
        }
        let fileOutput = [0u64]
        let sizeOutput = [0u64]
        let nativeCode = [0i64]
        let status = synchronized(mutex) {
            ensureRootOpen()
            unsafe {
                let pathRaw = acquireArrayRawData(path)
                let fileRaw = acquireArrayRawData(fileOutput)
                let sizeRaw = acquireArrayRawData(sizeOutput)
                let nativeRaw = acquireArrayRawData(nativeCode)
                try {
                    wirestack_http_files_download_open(
                        handle,
                        pathRaw.pointer,
                        UInt64(path.size),
                        UInt64(maximumBytes),
                        fileRaw.pointer,
                        sizeRaw.pointer,
                        nativeRaw.pointer
                    )
                } finally {
                    releaseArrayRawData(nativeRaw)
                    releaseArrayRawData(sizeRaw)
                    releaseArrayRawData(fileRaw)
                    releaseArrayRawData(pathRaw)
                }
            }
        }
        if (status != HTTP_FILES_OK || fileOutput[0] == 0u64 || sizeOutput[0] > UInt64(Int64.Max)) {
            if (fileOutput[0] != 0u64) { unsafe { wirestack_http_files_file_close(fileOutput[0]) } }
            throwHttpFiles(status, nativeCode[0], "download file could not be opened")
        }
        checkContextAfterOpen(context, fileOutput[0])
        NativeReadFile(fileOutput[0], Int64(sizeOutput[0]), context)
    }

    public func beginUpload(filename: String, maximumBytes: Int64,
        context: api.OperationContext): NativeUpload {
        if (maximumBytes < 0) {
            throw HttpFilesException(HttpFilesStatus.InvalidArgument, "upload byte limit is invalid")
        }
        checkContext(context)
        let bytes = filename.toArray()
        if (bytes.isEmpty() || bytes.size > 1024 || filename.contains("\0")) {
            throw HttpFilesException(HttpFilesStatus.InvalidArgument, "upload filename is invalid")
        }
        let output = [0u64]
        let nativeCode = [0i64]
        let status = synchronized(mutex) {
            ensureRootOpen()
            unsafe {
                let inputRaw = acquireArrayRawData(bytes)
                let outputRaw = acquireArrayRawData(output)
                let nativeRaw = acquireArrayRawData(nativeCode)
                try {
                    wirestack_http_files_upload_begin(
                        handle,
                        inputRaw.pointer,
                        UInt64(bytes.size),
                        UInt64(maximumBytes),
                        outputRaw.pointer,
                        nativeRaw.pointer
                    )
                } finally {
                    releaseArrayRawData(nativeRaw)
                    releaseArrayRawData(outputRaw)
                    releaseArrayRawData(inputRaw)
                }
            }
        }
        if (status != HTTP_FILES_OK || output[0] == 0u64) {
            if (output[0] != 0u64) {
                unsafe { wirestack_http_files_upload_abort(output[0]) }
            }
            throwHttpFiles(status, nativeCode[0], "upload staging file could not be created")
        }
        if (context.isCancellationRequested() || context.isDeadlineExceeded()) {
            unsafe { wirestack_http_files_upload_abort(output[0]) }
            checkContext(context)
        }
        NativeUpload(output[0], maximumBytes, context)
    }

    public func close(): Unit {
        synchronized(mutex) {
            if (!closed) {
                let current = handle
                handle = 0u64
                closed = true
                unsafe { wirestack_http_files_root_close(current) }
            }
        }
    }

    public func isClosed(): Bool { synchronized(mutex) { closed } }

    private func ensureRootOpen(): Unit {
        if (closed || handle == 0u64) {
            throw HttpFilesException(HttpFilesStatus.Closed, "file root is closed")
        }
    }
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
public class NativeReadFile <: api.HttpBodyStream {
    private let mutex = Mutex()
    private var handle: UInt64
    private let length: Int64
    private let context: api.OperationContext
    private var closed = false

    init(handle: UInt64, length: Int64, context: api.OperationContext) {
        this.handle = handle
        this.length = length
        this.context = context
    }

    public prop contentLength: ?Int64 { get() { Some(length) } }

    public func read(destination: Array<Byte>): Int64 {
        if (context.isCancellationRequested() || context.isDeadlineExceeded()) {
            close()
            checkContext(context)
        }
        if (destination.isEmpty()) {
            synchronized(mutex) { ensureOpen() }
            return 0
        }
        let countOutput = [0u64]
        let nativeCode = [0i64]
        let status = synchronized(mutex) {
            ensureOpen()
            unsafe {
                let destinationRaw = acquireArrayRawData(destination)
                let countRaw = acquireArrayRawData(countOutput)
                let nativeRaw = acquireArrayRawData(nativeCode)
                try {
                    wirestack_http_files_file_read(
                        handle,
                        destinationRaw.pointer,
                        UInt64(destination.size),
                        countRaw.pointer,
                        nativeRaw.pointer
                    )
                } finally {
                    releaseArrayRawData(nativeRaw)
                    releaseArrayRawData(countRaw)
                    releaseArrayRawData(destinationRaw)
                }
            }
        }
        if (status != HTTP_FILES_OK || countOutput[0] > UInt64(destination.size)) {
            close()
            throwHttpFiles(status, nativeCode[0], "download file read failed")
        }
        if (context.isCancellationRequested() || context.isDeadlineExceeded()) {
            close()
            checkContext(context)
        }
        Int64(countOutput[0])
    }

    public func close(): Unit {
        synchronized(mutex) {
            if (!closed) {
                let current = handle
                handle = 0u64
                closed = true
                unsafe { wirestack_http_files_file_close(current) }
            }
        }
    }

    public func isClosed(): Bool { synchronized(mutex) { closed } }

    private func ensureOpen(): Unit {
        if (closed || handle == 0u64) {
            throw HttpFilesException(HttpFilesStatus.Closed, "download file is closed")
        }
    }
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
public class NativeUpload <: Resource {
    private let mutex = Mutex()
    private var handle: UInt64
    private let maximumBytes: Int64
    private let context: api.OperationContext
    private var written: Int64 = 0
    private var closed = false

    init(handle: UInt64, maximumBytes: Int64, context: api.OperationContext) {
        this.handle = handle
        this.maximumBytes = maximumBytes
        this.context = context
    }

    public prop bytesWritten: Int64 { get() { synchronized(mutex) { written } } }

    public func write(value: Array<Byte>, count: Int64): Unit {
        if (count < 0 || count > value.size) {
            throw HttpFilesException(HttpFilesStatus.InvalidArgument, "upload write count is invalid")
        }
        if (context.isCancellationRequested() || context.isDeadlineExceeded()) {
            abort()
            checkContext(context)
        }
        if (count == 0) {
            synchronized(mutex) { ensureOpen() }
            return
        }
        let nativeCode = [0i64]
        let status = synchronized(mutex) {
            ensureOpen()
            if (count > maximumBytes - written) {
                throw HttpFilesException(HttpFilesStatus.LimitExceeded, "upload exceeds configured byte limit")
            }
            let result = unsafe {
                let inputRaw = acquireArrayRawData(value)
                let nativeRaw = acquireArrayRawData(nativeCode)
                try {
                    wirestack_http_files_upload_write(
                        handle,
                        inputRaw.pointer,
                        UInt64(count),
                        nativeRaw.pointer
                    )
                } finally {
                    releaseArrayRawData(nativeRaw)
                    releaseArrayRawData(inputRaw)
                }
            }
            if (result == HTTP_FILES_OK) { written += count }
            result
        }
        if (status != HTTP_FILES_OK) {
            abort()
            throwHttpFiles(status, nativeCode[0], "upload file write failed")
        }
        if (context.isCancellationRequested() || context.isDeadlineExceeded()) {
            abort()
            checkContext(context)
        }
    }

    public func commit(): Unit {
        if (context.isCancellationRequested() || context.isDeadlineExceeded()) {
            abort()
            checkContext(context)
        }
        let nativeCode = [0i64]
        let status = synchronized(mutex) {
            ensureOpen()
            let result = unsafe {
                let nativeRaw = acquireArrayRawData(nativeCode)
                try { wirestack_http_files_upload_commit(handle, nativeRaw.pointer) }
                finally { releaseArrayRawData(nativeRaw) }
            }
            if (result == HTTP_FILES_OK) {
                handle = 0u64
                closed = true
            }
            result
        }
        if (status != HTTP_FILES_OK) {
            abort()
            throwHttpFiles(status, nativeCode[0], "upload file could not be published atomically")
        }
    }

    public func abort(): Unit {
        synchronized(mutex) {
            if (!closed) {
                let current = handle
                handle = 0u64
                closed = true
                unsafe { wirestack_http_files_upload_abort(current) }
            }
        }
    }

    public func close(): Unit { abort() }
    public func isClosed(): Bool { synchronized(mutex) { closed } }

    private func ensureOpen(): Unit {
        if (closed || handle == 0u64) {
            throw HttpFilesException(HttpFilesStatus.Closed, "upload staging file is closed")
        }
    }
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func checkContext(context: api.OperationContext): Unit {
    if (context.isCancellationRequested()) {
        throw HttpFilesException(HttpFilesStatus.Cancelled, "trusted local filesystem operation was cancelled")
    }
    if (context.isDeadlineExceeded()) {
        throw HttpFilesException(HttpFilesStatus.DeadlineExceeded, "trusted local filesystem operation deadline exceeded")
    }
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func checkContextAfterOpen(context: api.OperationContext, handle: UInt64): Unit {
    if (context.isCancellationRequested() || context.isDeadlineExceeded()) {
        unsafe { wirestack_http_files_file_close(handle) }
        checkContext(context)
    }
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func throwHttpFiles(status: Int32, nativeCode: Int64, message: String): Nothing {
    let mapped = if (status == HTTP_FILES_INVALID_ARGUMENT) { HttpFilesStatus.InvalidArgument }
    else if (status == HTTP_FILES_OUT_OF_MEMORY) { HttpFilesStatus.OutOfMemory }
    else if (status == HTTP_FILES_NOT_FOUND) { HttpFilesStatus.NotFound }
    else if (status == HTTP_FILES_PERMISSION_DENIED) { HttpFilesStatus.PermissionDenied }
    else if (status == HTTP_FILES_SYMLINK_REJECTED) { HttpFilesStatus.SymlinkRejected }
    else if (status == HTTP_FILES_NONREGULAR) { HttpFilesStatus.Nonregular }
    else if (status == HTTP_FILES_LIMIT_EXCEEDED) { HttpFilesStatus.LimitExceeded }
    else if (status == HTTP_FILES_ALREADY_EXISTS) { HttpFilesStatus.AlreadyExists }
    else if (status == HTTP_FILES_CLOSED) { HttpFilesStatus.Closed }
    else if (status == HTTP_FILES_FILE_CHANGED) { HttpFilesStatus.FileChanged }
    else { HttpFilesStatus.SystemFailure }
    let code = if (nativeCode == 0) { None<Int64> } else { Some(nativeCode) }
    throw HttpFilesException(mapped, message, nativeCode: code)
}
