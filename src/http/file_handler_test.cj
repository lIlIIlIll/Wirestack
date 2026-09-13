package wirestack.http

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
import std.collection.ArrayList
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
import std.env.getVariable
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
import std.fs.*
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
import std.time.MonoTime
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
import std.unittest.*
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
import std.unittest.testmacro.*
@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
import wirestack.internal.http_files as files

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
foreign func symlink(target: CString, linkPath: CString): Int32

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
@Test
class FileHandlerTest {
    @TestCase
    func confinedDownloadRejectsTraversalAndSymlinkWhileOpenBodyOutlivesHandler(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        let outsideFile = File.createTemp("/tmp")
        let outsidePath = outsideFile.info.path.toString()
        outsideFile.close()
        File.writeTo(outsidePath, "outside".toArray())
        File.writeTo("${root}/inside.bin", [0u8, 1u8, 255u8, 2u8])
        createFileHandlerSymlink(outsidePath, "${root}/escape.bin")

        try {
            @AssertThrows[IllegalArgumentException](
                FileHandler.download(root, "../outside", maximumBytes: 64)
            )
            let handler = FileHandler.download(root, "inside.bin", maximumBytes: 64)
            let server = HttpServer.builder()
                .listen(fileHandlerLoopback(0))
                .handler(handler)
                .build()
            let serving: Future<Unit> = spawn { server.serve() }
            let client = fileHandlerClient(server, "files-download.test")
            try {
                let response = client.get(
                    "http://files-download.test:${server.localEndpoint.port}/download")
                @Expect(response.status, 200)
                handler.close()
                @Expect(readFileHandlerBody(response.body), [0u8, 1u8, 255u8, 2u8])
                response.close()
            } finally {
                client.close()
                let _ = server.shutdown(context: OperationContext(
                    deadline: Some(Deadline.after(Duration.second))
                ))
                serving.get(Duration.second)
                handler.close()
            }

            let symlinkHandler = FileHandler.download(root, "escape.bin", maximumBytes: 64)
            let symlinkServer = HttpServer.builder()
                .listen(fileHandlerLoopback(0))
                .handler(symlinkHandler)
                .build()
            let symlinkServing: Future<Unit> = spawn { symlinkServer.serve() }
            let symlinkClient = fileHandlerClient(symlinkServer, "files-symlink.test")
            try {
                let response = symlinkClient.get(
                    "http://files-symlink.test:${symlinkServer.localEndpoint.port}/download")
                @Expect(response.status, 400)
                response.close()
            } finally {
                symlinkClient.close()
                let _ = symlinkServer.shutdown(context: OperationContext(
                    deadline: Some(Deadline.after(Duration.second))
                ))
                symlinkServing.get(Duration.second)
                symlinkHandler.close()
            }
        } finally {
            let _ = removeIfExists(root, recursive: true)
            let _ = removeIfExists(outsidePath)
        }
    }

    @TestCase
    func uploadPublishesOneCompleteBinaryFileAndNeverPublishesRejectedMultipart(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        let handler = FileHandler.upload(root, maximumBytes: 64, bufferSize: 4096,
            validator: { name => name.endsWith(".bin") }, maximumParts: 4)
        let server = HttpServer.builder()
            .listen(fileHandlerLoopback(0))
            .handler(handler)
            .build()
        let serving: Future<Unit> = spawn { server.serve() }
        let client = fileHandlerClient(server, "files-upload.test")
        try {
            let acceptedWriter = MultipartWriter("upload-ok")
                .add(MultipartPart("file", [0u8, 255u8, 13u8, 10u8, 7u8],
                    filename: Some("accepted.bin")))
            let accepted = client.send(fileUploadRequest(
                server, "files-upload.test", acceptedWriter
            ))
            @Expect(accepted.status, 201)
            accepted.close()
            @Expect(readFileHandlerFile("${root}/accepted.bin"),
                [0u8, 255u8, 13u8, 10u8, 7u8])

            let rejectedWriter = MultipartWriter("upload-rejected")
                .add(MultipartPart("first", "first".toArray(),
                    filename: Some("first.bin")))
                .add(MultipartPart("second", "second".toArray(),
                    filename: Some("second.bin")))
            let rejected = client.send(fileUploadRequest(
                server, "files-upload.test", rejectedWriter
            ))
            @Expect(rejected.status, 400)
            rejected.close()
            @Expect(!exists("${root}/first.bin"))
            @Expect(!exists("${root}/second.bin"))

            let traversalWriter = MultipartWriter("upload-traversal")
                .add(MultipartPart("file", "escape".toArray(),
                    filename: Some("../escape.bin")))
            let traversal = client.send(fileUploadRequest(
                server, "files-upload.test", traversalWriter
            ))
            @Expect(traversal.status, 400)
            traversal.close()
            @Expect(!exists("${root}/escape.bin"))

            let oversizedWriter = MultipartWriter("upload-oversized",
                maximumPartBytes: 128)
                .add(MultipartPart("file", Array<Byte>(65, repeat: 7u8),
                    filename: Some("oversized.bin")))
            let oversized = client.send(fileUploadRequest(
                server, "files-upload.test", oversizedWriter
            ))
            @Expect(oversized.status, 413)
            oversized.close()
            @Expect(!exists("${root}/oversized.bin"))

            File.writeTo("${root}/existing.bin", "original".toArray())
            let existingWriter = MultipartWriter("upload-existing")
                .add(MultipartPart("file", "replacement".toArray(),
                    filename: Some("existing.bin")))
            let existing = client.send(fileUploadRequest(
                server, "files-upload.test", existingWriter
            ))
            @Expect(existing.status, 409)
            existing.close()
            @Expect(readFileHandlerFile("${root}/existing.bin"), "original".toArray())
        } finally {
            client.close()
            let _ = server.shutdown(context: OperationContext(
                deadline: Some(Deadline.after(Duration.second))
            ))
            serving.get(Duration.second)
            handler.close()
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func uploadCommitChecksContextAfterDurabilityBeforePublication(): Unit {
        match (getVariable("WIRESTACK_HTTP_FILES_COMMIT_SCENARIO")) {
            case Some(scenario) =>
                runUploadCommitBoundaryScenario(
                    requiredUploadCommitEnvironment("WIRESTACK_HTTP_FILES_COMMIT_ROOT"),
                    scenario,
                    gated: true
                )
            case None =>
                let root = Directory.createTemp("/tmp").toString()
                try {
                    runUploadCommitBoundaryScenario(root, "live", gated: false)
                } finally {
                    let _ = removeIfExists(root, recursive: true)
                }
        }
    }
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func runUploadCommitBoundaryScenario(root: String, scenario: String,
    gated!: Bool): Unit {
    if (scenario != "live" && scenario != "cancel" &&
        scenario != "deadline" && scenario != "cancel-existing") {
        throw IllegalArgumentException("unknown upload commit scenario: ${scenario}")
    }
    let destination = "${root}/commit-boundary.bin"
    let entered = if (gated) {
        requiredUploadCommitEnvironment("WIRESTACK_HTTP_FILES_COMMIT_ENTERED")
    } else {
        ""
    }
    let release = if (gated) {
        requiredUploadCommitEnvironment("WIRESTACK_HTTP_FILES_COMMIT_RELEASE")
    } else {
        ""
    }
    let cancellation = CancellationSource()
    let context = if (scenario == "deadline") {
        OperationContext(deadline: Some(Deadline.after(500 * Duration.millisecond)))
    } else {
        OperationContext(cancellation: cancellation.token)
    }
    let nativeRoot = files.HttpFilesRoot(root)
    let upload = nativeRoot.beginUpload("commit-boundary.bin", 64, context)
    upload.write("replacement".toArray(), 11)
    if (scenario == "cancel-existing") {
        File.writeTo(destination, "original".toArray())
    }
    let committing: Future<Int64> = spawn {
        exclusiveScope({ => uploadCommitBoundaryResult(upload) })
    }
    try {
        if (gated) {
            waitForUploadCommitState({ => exists(entered) })
            if (scenario == "cancel" || scenario == "cancel-existing") {
                cancellation.cancel()
            } else if (scenario == "deadline") {
                waitForUploadCommitState({ => context.isDeadlineExceeded() })
            }
            File.writeTo(release, [1u8])
        }
        let result = committing.get(5 * Duration.second)
        if (scenario == "live") {
            @Expect(result, 0)
            @Expect(readFileHandlerFile(destination), "replacement".toArray())
        } else if (scenario == "deadline") {
            @Expect(result, 2)
            @Expect(!exists(destination))
        } else if (scenario == "cancel-existing") {
            @Expect(result, 1)
            @Expect(readFileHandlerFile(destination), "original".toArray())
        } else {
            @Expect(result, 1)
            @Expect(!exists(destination))
        }
        @Expect(upload.isClosed())
    } finally {
        if (gated && !exists(release)) { File.writeTo(release, [1u8]) }
        upload.abort()
        nativeRoot.close()
    }
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func uploadCommitBoundaryResult(upload: files.NativeUpload): Int64 {
    try {
        upload.commit()
        0
    } catch (error: files.HttpFilesException) {
        match (error.status) {
            case files.HttpFilesStatus.Cancelled => 1
            case files.HttpFilesStatus.DeadlineExceeded => 2
            case _ => 3
        }
    }
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func waitForUploadCommitState(predicate: () -> Bool): Unit {
    let expiresAt = MonoTime.now() + 5 * Duration.second
    while (!predicate()) {
        if (MonoTime.now() >= expiresAt) {
            throw TimeoutException()
        }
        sleep(Duration.millisecond)
    }
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func requiredUploadCommitEnvironment(name: String): String {
    match (getVariable(name)) {
        case Some(value) =>
            if (value.isEmpty()) {
                throw IllegalArgumentException("empty upload commit environment: ${name}")
            }
            value
        case None => throw IllegalArgumentException("missing upload commit environment: ${name}")
    }
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func fileUploadRequest(server: HttpServer, host: String,
    writer: MultipartWriter): HttpRequest {
    let body = writer.body(maximumBytes: 4096)
    HttpRequest(
        HttpMethod("POST"),
        HttpUrl.parse("http://${host}:${server.localEndpoint.port}/upload"),
        headers: HttpHeaders.builder().add("Content-Type", writer.contentType())
            .add("Content-Length", "${body.contentLength.getOrThrow()}").build(),
        body: body
    )
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func fileHandlerLoopback(port: UInt16): SocketEndpoint {
    SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), port)
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func fileHandlerClient(server: HttpServer, host: String): HttpClient {
    let name = HostName(host)
    HttpClient.builder()
        .resolver(StaticResolver(ResolveResult(
            [server.localEndpoint.address], name, ResolverSource.Static
        )))
        .requestTimeout(3 * Duration.second)
        .build()
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func readFileHandlerBody(body: ResponseBody): Array<Byte> {
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(2, repeat: 0u8)
    while (true) {
        let count = body.read(buffer)
        if (count == 0) { break }
        for (index in 0..count) { output.add(buffer[index]) }
    }
    output.toArray()
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func readFileHandlerFile(path: String): Array<Byte> {
    let file = File(path, OpenMode.Read)
    try {
        let output = ArrayList<Byte>()
        let buffer = Array<Byte>(2, repeat: 0u8)
        while (true) {
            let count = file.read(buffer)
            if (count == 0) { break }
            for (index in 0..count) { output.add(buffer[index]) }
        }
        output.toArray()
    } finally { file.close() }
}

@When[os == "Linux" && arch == "x86_64" && env == "gnu"]
private func createFileHandlerSymlink(target: String, path: String): Unit {
    unsafe {
        let targetValue = LibC.mallocCString(target)
        let pathValue = LibC.mallocCString(path)
        try {
            if (symlink(targetValue, pathValue) != 0) {
                throw Exception("test symlink could not be created")
            }
        } finally {
            LibC.free(pathValue)
            LibC.free(targetValue)
        }
    }
}
