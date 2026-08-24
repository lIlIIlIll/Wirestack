package wirestack.internal.http1

import std.collection.ArrayList
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

public enum Http1RequestTargetForm {
    | Origin
    | Absolute
}

/** Immutable serialized head plus the framing decision used to create it. */
public class Http1SerializedHead {
    private let ownedBytes: Array<Byte>
    public let framing: Http1BodyFraming

    public prop bytes: Array<Byte> { get() { ownedBytes.clone() } }

    public init(bytes: Array<Byte>, framing: Http1BodyFraming) {
        ownedBytes = bytes.clone()
        this.framing = framing
    }
}

/** Serializes an already-selected HTTP/1 request target and validates its wire image. */
public func serializeRequestHead(
    method: HttpMethod,
    target: String,
    headers: HttpHeaders,
    limits!: HttpLimits = HttpLimits()
): Http1SerializedHead {
    let output = ArrayList<Byte>()
    appendText(output, "${method} ${target} HTTP/1.1\r\n")
    appendHeaders(output, headers)
    appendText(output, "\r\n")
    let bytes = output.toArray()
    let parsed = match (Http1RequestHeadParser(limits: limits).feed(bytes)) {
        case Some(value) => value
        case None => throw Http1ParseException(Http1ParseErrorCode.InvalidStartLine, "serialized request head is incomplete")
    }
    if (!parsed.remaining.isEmpty()) {
        throw Http1ParseException(Http1ParseErrorCode.InvalidHeader, "serialized request head retained unexpected bytes")
    }
    Http1SerializedHead(bytes, parsed.head.framing)
}

/** Adds or validates Host from a normalized URL and emits origin-form for direct requests. */
public func serializeClientRequestHead(
    method: HttpMethod,
    url: HttpUrl,
    headers: HttpHeaders,
    targetForm!: Http1RequestTargetForm = Http1RequestTargetForm.Origin,
    limits!: HttpLimits = HttpLimits()
): Http1SerializedHead {
    let connectAuthority = if (url.host.contains(":")) {
        "[${url.host}]:${url.port}"
    } else {
        "${url.host}:${url.port}"
    }
    let builder = HttpHeaders.builder(limits: limits)
    for (entry in headers.entries) { builder.add(entry.name, entry.value) }
    let hosts = headers.getAll("host")
    if (hosts.isEmpty()) {
        builder.add("Host", if (method == HttpMethod("CONNECT")) { connectAuthority } else { url.authority })
    } else {
        if (hosts.size != 1) {
            throw Http1ParseException(Http1ParseErrorCode.MissingOrDuplicateHost, "client request requires exactly one Host field")
        }
        let supplied = try {
            HttpUrl.parse("${url.scheme}://${hosts[0]}/")
        } catch (_: IllegalArgumentException) {
            throw Http1ParseException(Http1ParseErrorCode.MissingOrDuplicateHost, "client Host field is invalid")
        }
        if (supplied.host.toAsciiLower() != url.host.toAsciiLower() || supplied.port != url.port) {
            throw Http1ParseException(Http1ParseErrorCode.MissingOrDuplicateHost, "client Host field differs from request URL origin")
        }
        if (method == HttpMethod("CONNECT")) { builder.set("Host", connectAuthority) }
    }
    let target = if (method == HttpMethod("CONNECT")) {
        connectAuthority
    } else {
        match (targetForm) {
            case Http1RequestTargetForm.Origin => url.requestTarget
            case Http1RequestTargetForm.Absolute => url.toString()
        }
    }
    serializeRequestHead(method, target, builder.build(), limits: limits)
}

/** Serializes an HTTP/1 response head with the same framing rules as the parser. */
public func serializeResponseHead(
    status: UInt16,
    reason: String,
    headers: HttpHeaders,
    requestMethod: HttpMethod,
    limits!: HttpLimits = HttpLimits()
): Http1SerializedHead {
    let output = ArrayList<Byte>()
    appendText(output, "HTTP/1.1 ${status} ${reason}\r\n")
    appendHeaders(output, headers)
    appendText(output, "\r\n")
    let bytes = output.toArray()
    let parsed = match (Http1ResponseHeadParser(requestMethod, limits: limits).feed(bytes)) {
        case Some(value) => value
        case None => throw Http1ParseException(Http1ParseErrorCode.InvalidStartLine, "serialized response head is incomplete")
    }
    if (!parsed.remaining.isEmpty()) {
        throw Http1ParseException(Http1ParseErrorCode.InvalidHeader, "serialized response head retained unexpected bytes")
    }
    Http1SerializedHead(bytes, parsed.head.framing)
}

/** Writes through the transport's partial-write loop under one operation budget. */
public func writeSerializedHead(
    transport: DuplexTransport,
    head: Http1SerializedHead,
    context!: OperationContext = OperationContext.background()
): Unit {
    writeAll(transport, ByteSpan(head.bytes), context: context)
}

private func appendHeaders(output: ArrayList<Byte>, headers: HttpHeaders): Unit {
    for (entry in headers.entries) {
        appendText(output, entry.name)
        appendText(output, ": ")
        appendText(output, entry.value)
        appendText(output, "\r\n")
    }
}

private func appendText(output: ArrayList<Byte>, value: String): Unit {
    for (byte in value.toArray()) { output.add(byte) }
}
