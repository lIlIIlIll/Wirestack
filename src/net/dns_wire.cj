package wirestack.net

import std.collection.ArrayList
import wirestack as api

private const DNS_HEADER_BYTES: Int64 = 12
private const DNS_CLASS_IN: Int64 = 1

/** DNS resource-record types decoded by the bounded wire parser. */
public enum DnsRecordType {
    /** IPv4 address record (type 1). */
    | A
    /** IPv6 address record (type 28). */
    | AAAA
    /** Canonical-name record (type 5). */
    | CNAME
    /** Service-location record (type 33). */
    | SRV
    /** Length-prefixed binary text record (type 16). */
    | TXT
    /** Mail-exchange record (type 15). */
    | MX
    /** Reverse-pointer record (type 12). */
    | PTR
    /** Start-of-authority record (type 6). */
    | SOA
    /** An otherwise well-formed record whose numeric type is not decoded. */
    | Unknown(Int64)
}

/** One validated DNS question in canonical lowercase ASCII form. */
public struct DnsQuestion {
    /** Canonical name; the root is represented as `.`. */
    public let name: String
    /** Requested resource-record type. */
    public let recordType: DnsRecordType
    /** Numeric DNS class, normally IN (1). */
    public let recordClass: UInt16

    internal init(name: String, recordType: DnsRecordType, recordClass: UInt16) {
        this.name = name
        this.recordType = recordType
        this.recordClass = recordClass
    }
}

/** One validated DNS resource record with owned RDATA. */
public struct DnsRecord {
    /** Canonical owner name; the root is represented as `.`. */
    public let name: String
    /** Resource-record type. */
    public let recordType: DnsRecordType
    /** Numeric DNS class, normally IN (1). */
    public let recordClass: UInt16
    /** Record time-to-live in seconds. */
    public let ttl: UInt32
    /** Canonical CNAME, PTR, MX, or SRV target when that record has one. */
    public let targetName: ?String
    /** RFC 2308 negative-caching minimum from an SOA record, when present. */
    public let soaMinimum: ?UInt32
    private let ownedData: Array<Byte>

    internal init(
        name: String,
        recordType: DnsRecordType,
        recordClass: UInt16,
        ttl: UInt32,
        data: Array<Byte>,
        targetName!: ?String = None<String>,
        soaMinimum!: ?UInt32 = None<UInt32>
    ) {
        this.name = name
        this.recordType = recordType
        this.recordClass = recordClass
        this.ttl = ttl
        this.ownedData = data.clone()
        this.targetName = targetName
        this.soaMinimum = soaMinimum
    }

    /** Returns a defensive copy of the exact wire RDATA. */
    public func data(): Array<Byte> { ownedData.clone() }
}

/** Header and ordered sections from one validated DNS message. */
public struct DnsMessageSummary {
    /** Transaction identifier from the DNS header. */
    public let transactionId: UInt16
    /** Whether the QR response bit is set. */
    public let isResponse: Bool
    /** Numeric four-bit DNS opcode. */
    public let opcode: Int64
    /** Number of answer records declared by the header. */
    public let answerCount: Int64
    /** Whether the TC truncation bit is set. */
    public let truncated: Bool
    /** Numeric four-bit DNS response code. */
    public let responseCode: Int64
    /** Number of question entries declared by the header. */
    public let questionCount: Int64
    /** Number of authority records declared by the header. */
    public let authorityCount: Int64
    /** Number of additional records declared by the header. */
    public let additionalCount: Int64
    /** Validated question entries owned by this summary. */
    public let questions: Array<DnsQuestion>
    /**
     * Validated records owned by this summary.
     *
     * Full-parser results are ordered as answers, then authorities, then
     * additionals. `dnsResponseQuestion` intentionally returns no records.
     */
    public let records: Array<DnsRecord>

    /** Creates a complete, internally consistent DNS message summary.
     *
     * @param transactionId DNS transaction identifier.
     * @param answerCount Number of leading answer records in `records`.
     * @param truncated Whether the DNS TC bit is set.
     * @param isResponse Whether the DNS QR bit is set.
     * @param opcode Numeric DNS opcode from 0 through 15.
     * @param responseCode Numeric DNS response code from 0 through 15.
     * @param questionCount Number of entries in `questions`.
     * @param authorityCount Number of authority records following the answers.
     * @param additionalCount Number of additional records following authorities.
     * @param questions Validated question entries; the value owns a copy.
     * @param records Answer, authority, and additional records in that order; the value owns a copy.
     */
    public init(
        transactionId: UInt16,
        answerCount: Int64,
        truncated: Bool,
        isResponse!: Bool = true,
        opcode!: Int64 = 0,
        responseCode!: Int64 = 0,
        questionCount!: Int64 = 0,
        authorityCount!: Int64 = 0,
        additionalCount!: Int64 = 0,
        questions!: Array<DnsQuestion> = Array<DnsQuestion>(),
        records!: Array<DnsRecord> = Array<DnsRecord>()
    ) {
        validateDnsSummaryCounts(
            answerCount, questionCount, authorityCount, additionalCount,
            opcode, responseCode, questions.size, records.size, false
        )
        this.transactionId = transactionId
        this.isResponse = isResponse
        this.opcode = opcode
        this.answerCount = answerCount
        this.truncated = truncated
        this.responseCode = responseCode
        this.questionCount = questionCount
        this.authorityCount = authorityCount
        this.additionalCount = additionalCount
        this.questions = questions.clone()
        this.records = records.clone()
    }

    internal init(
        transactionId: UInt16,
        answerCount: Int64,
        truncated: Bool,
        isResponse: Bool,
        opcode: Int64,
        responseCode: Int64,
        questionCount: Int64,
        authorityCount: Int64,
        additionalCount: Int64,
        questions: Array<DnsQuestion>,
        records: Array<DnsRecord>,
        headerOnly: Bool
    ) {
        validateDnsSummaryCounts(
            answerCount, questionCount, authorityCount, additionalCount,
            opcode, responseCode, questions.size, records.size, headerOnly
        )
        this.transactionId = transactionId
        this.isResponse = isResponse
        this.opcode = opcode
        this.answerCount = answerCount
        this.truncated = truncated
        this.responseCode = responseCode
        this.questionCount = questionCount
        this.authorityCount = authorityCount
        this.additionalCount = additionalCount
        this.questions = questions
        this.records = records
    }
}

/** Explicit work and allocation limits for hostile DNS messages. */
public struct DnsParserLimits {
    /** Maximum accepted DNS message size in bytes. */
    public let maximumMessageBytes: Int64
    /** Maximum expanded presentation-form name size in ASCII bytes. */
    public let maximumNameBytes: Int64
    /** Maximum compression-pointer hops while expanding one name. */
    public let maximumIndirections: Int64
    /** Maximum combined answer, authority, and additional record count. */
    public let maximumRecords: Int64
    /** Maximum question count. */
    public let maximumQuestions: Int64

    /** Creates bounded parser limits.
     *
     * @param maximumMessageBytes Maximum wire message size, from 12 through 65,535 bytes.
     * @param maximumNameBytes Maximum expanded ASCII name size, from 1 through 253 bytes.
     * @param maximumIndirections Maximum compression-pointer hops, from 1 through 128.
     * @param maximumRecords Maximum combined resource-record count, from 1 through 65,535.
     * @param maximumQuestions Maximum question count, from 1 through 65,535.
     */
    public init(
        maximumMessageBytes!: Int64 = 65535,
        maximumNameBytes!: Int64 = 253,
        maximumIndirections!: Int64 = 32,
        maximumRecords!: Int64 = 1024,
        maximumQuestions!: Int64 = 16
    ) {
        if (maximumMessageBytes < DNS_HEADER_BYTES || maximumMessageBytes > 65535 ||
            maximumNameBytes <= 0 || maximumNameBytes > 253 ||
            maximumIndirections <= 0 || maximumIndirections > 128 ||
            maximumRecords <= 0 || maximumRecords > 65535 ||
            maximumQuestions <= 0 || maximumQuestions > 65535) {
            throw IllegalArgumentException("DNS parser limits are outside the bounded range")
        }
        this.maximumMessageBytes = maximumMessageBytes
        this.maximumNameBytes = maximumNameBytes
        this.maximumIndirections = maximumIndirections
        this.maximumRecords = maximumRecords
        this.maximumQuestions = maximumQuestions
    }
}

/** Strict bounded parser for complete DNS messages. */
public class DnsMessageParser {
    /** Limits applied independently to every parse operation. */
    public let limits: DnsParserLimits

    /** Creates a DNS parser with explicit hostile-input bounds.
     *
     * @param limits Work, allocation, and message-size limits.
     */
    public init(limits!: DnsParserLimits = DnsParserLimits()) { this.limits = limits }

    /** Parses all declared sections and rejects truncation or trailing bytes.
     *
     * DNS names use Wirestack's canonical ASCII profile: labels contain only
     * letters, digits, hyphen, or underscore; a label may start or end with an
     * underscore but not a hyphen. ASCII letters are lowercased, and the root
     * is represented as `.`. Arbitrary binary content remains available in TXT
     * and unknown-record RDATA rather than being decoded as a name.
     *
     * @param message Complete DNS wire message bytes retained only for this call.
     * @return An owned summary with records ordered answer, authority, additional.
     */
    public func parse(message: Array<Byte>): DnsMessageSummary {
        let header = parseDnsHeader(message, limits)
        let nameState = DnsNameState(message.size)
        let (questions, afterQuestions) = parseDnsQuestions(
            message, DNS_HEADER_BYTES, header.questionCount, limits, nameState
        )
        var offset = afterQuestions
        let records = ArrayList<DnsRecord>()
        for (_ in 0..header.recordCount) {
            let (record, next) = parseDnsRecord(message, offset, limits, nameState)
            records.add(record)
            offset = next
        }
        if (offset != message.size) { dnsMalformed("DNS message contains bytes outside its declared sections") }
        DnsMessageSummary(
            header.transactionId,
            header.answerCount,
            header.truncated,
            header.isResponse,
            header.opcode,
            header.responseCode,
            header.questionCount,
            header.authorityCount,
            header.additionalCount,
            questions,
            records.toArray(),
            false
        )
    }
}

private struct ParsedDnsHeader {
    let transactionId: UInt16
    let isResponse: Bool
    let opcode: Int64
    let truncated: Bool
    let responseCode: Int64
    let questionCount: Int64
    let answerCount: Int64
    let authorityCount: Int64
    let additionalCount: Int64
    let recordCount: Int64

    init(
        transactionId: UInt16,
        isResponse: Bool,
        opcode: Int64,
        truncated: Bool,
        responseCode: Int64,
        questionCount: Int64,
        answerCount: Int64,
        authorityCount: Int64,
        additionalCount: Int64
    ) {
        this.transactionId = transactionId
        this.isResponse = isResponse
        this.opcode = opcode
        this.truncated = truncated
        this.responseCode = responseCode
        this.questionCount = questionCount
        this.answerCount = answerCount
        this.authorityCount = authorityCount
        this.additionalCount = additionalCount
        this.recordCount = answerCount + authorityCount + additionalCount
    }
}

private class DnsNameState {
    private let knownOffsets: Array<Bool>

    init(messageSize: Int64) {
        knownOffsets = Array<Bool>(messageSize, repeat: false)
    }

    func mark(offset: Int64): Unit { knownOffsets[offset] = true }

    func isKnown(offset: Int64): Bool { knownOffsets[offset] }
}


private func parseDnsHeader(message: Array<Byte>, limits: DnsParserLimits): ParsedDnsHeader {
    if (message.size < DNS_HEADER_BYTES || message.size > limits.maximumMessageBytes) {
        dnsMalformed("DNS message length is outside the configured bounds")
    }
    let flags = dnsReadU16(message, 2)
    if ((flags & 0x0040u16) != 0u16) { dnsMalformed("DNS header uses the reserved Z flag") }
    let questions = Int64(dnsReadU16(message, 4))
    let answers = Int64(dnsReadU16(message, 6))
    let authority = Int64(dnsReadU16(message, 8))
    let additional = Int64(dnsReadU16(message, 10))
    let records = answers + authority + additional
    if (questions > limits.maximumQuestions) { dnsMalformed("DNS question count exceeds the configured limit") }
    if (records > limits.maximumRecords) { dnsMalformed("DNS record count exceeds the configured limit") }
    ParsedDnsHeader(
        dnsReadU16(message, 0),
        (flags & 0x8000u16) != 0u16,
        Int64((flags >> 11) & 0x000Fu16),
        (flags & 0x0200u16) != 0u16,
        Int64(flags & 0x000Fu16),
        questions,
        answers,
        authority,
        additional
    )
}

private func parseDnsQuestions(
    message: Array<Byte>,
    start: Int64,
    count: Int64,
    limits: DnsParserLimits,
    nameState: DnsNameState
): (Array<DnsQuestion>, Int64) {
    var offset = start
    let questions = ArrayList<DnsQuestion>()
    for (_ in 0..count) {
        let (name, afterName) = parseCompressedDnsName(message, offset, limits, nameState)
        if (afterName > message.size - 4) { dnsMalformed("DNS question is truncated") }
        let typeCode = Int64(dnsReadU16(message, afterName))
        let classCode = dnsReadU16(message, afterName + 2)
        questions.add(DnsQuestion(name, dnsRecordType(typeCode), classCode))
        offset = afterName + 4
    }
    (questions.toArray(), offset)
}

private func parseDnsRecord(
    message: Array<Byte>,
    start: Int64,
    limits: DnsParserLimits,
    nameState: DnsNameState
): (DnsRecord, Int64) {
    let (name, afterName) = parseCompressedDnsName(message, start, limits, nameState)
    if (afterName > message.size - 10) { dnsMalformed("DNS resource-record header is truncated") }
    let typeCode = Int64(dnsReadU16(message, afterName))
    let recordClass = dnsReadU16(message, afterName + 2)
    let ttl = dnsReadU32(message, afterName + 4)
    let dataLength = Int64(dnsReadU16(message, afterName + 8))
    let dataStart = afterName + 10
    if (dataLength > message.size - dataStart) { dnsMalformed("DNS resource-record data is truncated") }
    let dataEnd = dataStart + dataLength
    let recordType = dnsRecordType(typeCode)
    var targetName: ?String = None<String>
    var soaMinimum: ?UInt32 = None<UInt32>

    match (recordType) {
        case DnsRecordType.A =>
            if (dataLength != 4) { dnsMalformed("A record RDATA must contain exactly four bytes") }
        case DnsRecordType.AAAA =>
            if (dataLength != 16) { dnsMalformed("AAAA record RDATA must contain exactly sixteen bytes") }
        case DnsRecordType.CNAME | DnsRecordType.PTR =>
            if (dataLength < 1) { dnsMalformed("DNS target-name RDATA is empty") }
            let (target, next) = parseCompressedDnsName(message, dataStart, limits, nameState)
            if (next != dataEnd) { dnsMalformed("DNS target name does not exactly consume its RDATA") }
            targetName = Some(target)
        case DnsRecordType.MX =>
            if (dataLength < 3) { dnsMalformed("MX record RDATA is too short") }
            let (target, next) = parseCompressedDnsName(message, dataStart + 2, limits, nameState)
            if (next != dataEnd) { dnsMalformed("MX target does not exactly consume its RDATA") }
            targetName = Some(target)
        case DnsRecordType.SRV =>
            if (dataLength < 7) { dnsMalformed("SRV record RDATA is too short") }
            let (target, next) = parseUncompressedDnsName(message, dataStart + 6, dataEnd, limits, nameState)
            if (next != dataEnd) { dnsMalformed("SRV target does not exactly consume its RDATA") }
            targetName = Some(target)
        case DnsRecordType.TXT => validateDnsTxt(message, dataStart, dataEnd)
        case DnsRecordType.SOA =>
            if (dataLength < 22) { dnsMalformed("SOA record RDATA is too short") }
            let (primary, afterPrimary) = parseCompressedDnsName(message, dataStart, limits, nameState)
            let _ = primary
            if (afterPrimary >= dataEnd) { dnsMalformed("SOA primary name escapes its RDATA") }
            let (mailbox, afterMailbox) = parseCompressedDnsName(message, afterPrimary, limits, nameState)
            let _ = mailbox
            if (afterMailbox > dataEnd || dataEnd - afterMailbox != 20) {
                dnsMalformed("SOA RDATA must end with exactly five 32-bit fields")
            }
            soaMinimum = Some(dnsReadU32(message, afterMailbox + 16))
        case DnsRecordType.Unknown(code) =>
            // RFC 1035 legacy name fields can be compression targets for later records.
            let nameCount = match (code) {
                case 2 | 3 | 4 | 7 | 8 | 9 => 1
                case 14 => 2
                case _ => 0
            }
            if (nameCount > 0) {
                var cursor = dataStart
                for (_ in 0..nameCount) {
                    if (cursor >= dataEnd) { dnsMalformed("DNS legacy name RDATA is truncated") }
                    let (_, next) = parseCompressedDnsName(message, cursor, limits, nameState)
                    if (next > dataEnd) { dnsMalformed("DNS legacy name escapes its RDATA") }
                    cursor = next
                }
                if (cursor != dataEnd) { dnsMalformed("DNS legacy names do not exactly consume their RDATA") }
            }
    }

    let data = dnsCopyRange(message, dataStart, dataEnd)
    (
        DnsRecord(
            name, recordType, recordClass, ttl, data,
            targetName: targetName, soaMinimum: soaMinimum
        ),
        dataEnd
    )
}

private func parseCompressedDnsName(
    message: Array<Byte>,
    start: Int64,
    limits: DnsParserLimits,
    nameState: DnsNameState
): (String, Int64) {
    if (start < DNS_HEADER_BYTES || start >= message.size) {
        dnsMalformed("DNS name offset is outside the message")
    }
    var cursor = start
    var next = start
    var jumped = false
    var hops: Int64 = 0
    var expandedBytes: Int64 = 0
    let labels = ArrayList<String>()
    let seenPointers = ArrayList<Int64>()

    while (true) {
        if (cursor >= message.size) { dnsMalformed("DNS name is truncated") }
        let marker = message[cursor]
        if ((marker & 0xC0u8) == 0xC0u8) {
            if (cursor + 1 >= message.size) { dnsMalformed("DNS compression pointer is truncated") }
            let pointer = Int64((UInt16(marker & 0x3Fu8) << 8) | UInt16(message[cursor + 1]))
            if (pointer < DNS_HEADER_BYTES || pointer >= cursor || pointer >= message.size ||
                !nameState.isKnown(pointer)) {
                dnsMalformed("DNS compression pointer does not reference an earlier validated label")
            }
            if (hops >= limits.maximumIndirections) { dnsMalformed("DNS compression indirection limit exceeded") }
            for (seen in seenPointers) {
                if (seen == pointer) { dnsMalformed("DNS compression loop detected") }
            }
            seenPointers.add(pointer)
            nameState.mark(cursor)
            hops += 1
            if (!jumped) {
                next = cursor + 2
                jumped = true
            }
            cursor = pointer
            continue
        }
        if ((marker & 0xC0u8) != 0u8) { dnsMalformed("DNS label uses a reserved length encoding") }
        let length = Int64(marker)
        if (length == 0) {
            nameState.mark(cursor)
            if (!jumped) { next = cursor + 1 }
            break
        }
        if (cursor + 1 > message.size - length) { dnsMalformed("DNS label exceeds the message bounds") }
        let label = canonicalDnsLabel(message, cursor + 1, length)
        nameState.mark(cursor)
        expandedBytes += if (labels.isEmpty()) { length } else { length + 1 }
        if (expandedBytes > limits.maximumNameBytes) { dnsMalformed("DNS name exceeds the expanded-name limit") }
        labels.add(label)
        cursor += 1 + length
    }
    (dnsJoinLabels(labels), next)
}

private func parseUncompressedDnsName(
    message: Array<Byte>,
    start: Int64,
    end: Int64,
    limits: DnsParserLimits,
    nameState: DnsNameState
): (String, Int64) {
    if (start < DNS_HEADER_BYTES || start >= end || end > message.size) {
        dnsMalformed("uncompressed DNS name bounds are invalid")
    }
    var cursor = start
    var expandedBytes: Int64 = 0
    let labels = ArrayList<String>()
    while (cursor < end) {
        let marker = message[cursor]
        if ((marker & 0xC0u8) != 0u8) { dnsMalformed("SRV target must not use DNS name compression") }
        let length = Int64(marker)
        if (length == 0) {
            nameState.mark(cursor)
            return (dnsJoinLabels(labels), cursor + 1)
        }
        if (cursor + 1 > end - length) { dnsMalformed("uncompressed DNS label escapes its RDATA") }
        let label = canonicalDnsLabel(message, cursor + 1, length)
        nameState.mark(cursor)
        expandedBytes += if (labels.isEmpty()) { length } else { length + 1 }
        if (expandedBytes > limits.maximumNameBytes) { dnsMalformed("DNS name exceeds the expanded-name limit") }
        labels.add(label)
        cursor += 1 + length
    }
    dnsMalformed("uncompressed DNS name is truncated")
}

private func canonicalDnsLabel(message: Array<Byte>, start: Int64, length: Int64): String {
    if (length <= 0 || length > 63) { dnsMalformed("DNS label length is invalid") }
    let output = Array<Byte>(length, repeat: 0u8)
    for (index in 0..length) {
        let value = message[start + index]
        if (!dnsAsciiLabelByte(value)) { dnsMalformed("DNS name contains an unsupported label byte") }
        output[index] = dnsAsciiLower(value)
    }
    if (!dnsAsciiLabelEdge(output[0]) || !dnsAsciiLabelEdge(output[output.size - 1])) {
        dnsMalformed("DNS label may not start or end with a hyphen")
    }
    String.fromUtf8(output)
}

private func dnsJoinLabels(labels: ArrayList<String>): String {
    if (labels.isEmpty()) { return "." }
    var result = ""
    for (index in 0..labels.size) {
        if (index > 0) { result += "." }
        result += labels[index]
    }
    result
}

private func validateDnsTxt(message: Array<Byte>, start: Int64, end: Int64): Unit {
    if (start == end) { dnsMalformed("TXT RDATA must contain at least one length-prefixed segment") }
    var cursor = start
    while (cursor < end) {
        let length = Int64(message[cursor])
        cursor += 1
        if (length > end - cursor) { dnsMalformed("TXT segment exceeds its RDATA") }
        cursor += length
    }
}

/** Canonicalizes and validates a name for DNS question identity.
 *
 * The accepted profile is ASCII letters, digits, hyphen, and underscore.
 * Hyphen cannot be the first or last label byte; underscore may be, allowing
 * service labels such as `_https._tcp.example`. One trailing root dot is
 * removed, ASCII letters are lowercased, and the root remains `.`.
 *
 * @param name Presentation-form DNS name.
 * @return Canonical lowercase identity used for query/response comparison.
 */
internal func dnsCanonicalName(name: String): String {
    if (name == ".") { return "." }
    let input = name.toArray()
    if (input.isEmpty()) { dnsInvalidName("DNS name must not be empty") }
    var end = input.size
    if (input[end - 1] == b'.') { end -= 1 }
    if (end <= 0 || end > 253) { dnsInvalidName("DNS name length is outside the supported ASCII profile") }
    let labels = ArrayList<String>()
    var labelStart: Int64 = 0
    var index: Int64 = 0
    while (index <= end) {
        if (index == end || input[index] == b'.') {
            let length = index - labelStart
            if (length <= 0 || length > 63) { dnsInvalidName("DNS label length is outside the supported range") }
            let output = Array<Byte>(length, repeat: 0u8)
            for (offset in 0..length) {
                let value = input[labelStart + offset]
                if (!dnsAsciiLabelByte(value)) { dnsInvalidName("DNS name contains a non-ASCII or unsupported label byte") }
                output[offset] = dnsAsciiLower(value)
            }
            if (!dnsAsciiLabelEdge(output[0]) || !dnsAsciiLabelEdge(output[output.size - 1])) {
                dnsInvalidName("DNS label may not start or end with a hyphen")
            }
            labels.add(String.fromUtf8(output))
            labelStart = index + 1
        }
        index += 1
    }
    dnsJoinLabels(labels)
}

/** Encodes one recursion-desired IN-class DNS query.
 *
 * @param name ASCII DNS name accepted by `dnsCanonicalName`.
 * @param recordType Resource-record type; unknown numeric values must be 1 through 65,535.
 * @param id Transaction identifier.
 * @return Newly owned DNS query bytes with exactly one question.
 */
internal func dnsEncodeQuery(name: String, recordType: DnsRecordType, id: UInt16): Array<Byte> {
    let canonical = dnsCanonicalName(name)
    let typeCode = dnsTypeCode(recordType)
    if (typeCode <= 0 || typeCode > 65535) { dnsInvalidName("DNS query type is outside the 16-bit range") }
    let output = ArrayList<Byte>()
    appendDnsU16(output, Int64(id))
    appendDnsU16(output, 0x0100)
    appendDnsU16(output, 1)
    appendDnsU16(output, 0)
    appendDnsU16(output, 0)
    appendDnsU16(output, 0)
    if (canonical == ".") {
        output.add(0u8)
    } else {
        for (label in canonical.split(".")) {
            let bytes = label.toArray()
            output.add(UInt8(UInt64(bytes.size)))
            for (value in bytes) { output.add(value) }
        }
        output.add(0u8)
    }
    appendDnsU16(output, typeCode)
    appendDnsU16(output, DNS_CLASS_IN)
    output.toArray()
}

/** Parses a bounded DNS response header and all questions without reading RRs.
 *
 * This envelope parser requires QR and validates every question. It deliberately
 * leaves `records` empty even when record counts are non-zero, allowing a TC
 * response's identity to be checked before an incomplete RR body is retried over
 * TCP. The complete parser remains strict.
 *
 * @param message DNS response bytes containing at least the complete question section.
 * @param limits Bounds applied to the header, questions, names, and message size.
 * @return Owned header/question summary; record counts retain their wire values.
 */
internal func dnsResponseQuestion(
    message: Array<Byte>,
    limits: DnsParserLimits
): DnsMessageSummary {
    let header = parseDnsHeader(message, limits)
    if (!header.isResponse) { dnsMalformed("DNS response envelope is missing the QR bit") }
    let nameState = DnsNameState(message.size)
    let (questions, _) = parseDnsQuestions(
        message, DNS_HEADER_BYTES, header.questionCount, limits, nameState
    )
    DnsMessageSummary(
        header.transactionId,
        header.answerCount,
        header.truncated,
        header.isResponse,
        header.opcode,
        header.responseCode,
        header.questionCount,
        header.authorityCount,
        header.additionalCount,
        questions,
        Array<DnsRecord>(),
        true
    )
}

internal func dnsTypeCode(recordType: DnsRecordType): Int64 {
    match (recordType) {
        case DnsRecordType.A => 1
        case DnsRecordType.AAAA => 28
        case DnsRecordType.CNAME => 5
        case DnsRecordType.SRV => 33
        case DnsRecordType.TXT => 16
        case DnsRecordType.MX => 15
        case DnsRecordType.PTR => 12
        case DnsRecordType.SOA => 6
        case DnsRecordType.Unknown(value) => value
    }
}

private func dnsRecordType(code: Int64): DnsRecordType {
    match (code) {
        case 1 => DnsRecordType.A
        case 28 => DnsRecordType.AAAA
        case 5 => DnsRecordType.CNAME
        case 33 => DnsRecordType.SRV
        case 16 => DnsRecordType.TXT
        case 15 => DnsRecordType.MX
        case 12 => DnsRecordType.PTR
        case 6 => DnsRecordType.SOA
        case _ => DnsRecordType.Unknown(code)
    }
}

private func dnsReadU16(bytes: Array<Byte>, offset: Int64): UInt16 {
    (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
}

private func dnsReadU32(bytes: Array<Byte>, offset: Int64): UInt32 {
    (UInt32(bytes[offset]) << 24) |
        (UInt32(bytes[offset + 1]) << 16) |
        (UInt32(bytes[offset + 2]) << 8) |
        UInt32(bytes[offset + 3])
}

private func appendDnsU16(output: ArrayList<Byte>, value: Int64): Unit {
    output.add(UInt8(UInt64((value >> 8) & 0xFF)))
    output.add(UInt8(UInt64(value & 0xFF)))
}

private func dnsCopyRange(bytes: Array<Byte>, start: Int64, end: Int64): Array<Byte> {
    let result = Array<Byte>(end - start, repeat: 0u8)
    for (index in start..end) { result[index - start] = bytes[index] }
    result
}

private func dnsAsciiLabelByte(value: Byte): Bool {
    dnsAsciiAlphaNumeric(value) || value == b'-' || value == b'_'
}

private func dnsAsciiLabelEdge(value: Byte): Bool {
    dnsAsciiAlphaNumeric(value) || value == b'_'
}

private func dnsAsciiAlphaNumeric(value: Byte): Bool {
    (value >= b'a' && value <= b'z') ||
        (value >= b'A' && value <= b'Z') ||
        (value >= b'0' && value <= b'9')
}

private func dnsAsciiLower(value: Byte): Byte {
    if (value >= b'A' && value <= b'Z') { value + 32u8 } else { value }
}

private func validateDnsSummaryCounts(
    answerCount: Int64,
    questionCount: Int64,
    authorityCount: Int64,
    additionalCount: Int64,
    opcode: Int64,
    responseCode: Int64,
    actualQuestions: Int64,
    actualRecords: Int64,
    headerOnly: Bool
): Unit {
    if (answerCount < 0 || questionCount < 0 || authorityCount < 0 || additionalCount < 0) {
        throw IllegalArgumentException("DNS section counts must be non-negative")
    }
    if (opcode < 0 || opcode > 15 || responseCode < 0 || responseCode > 15) {
        throw IllegalArgumentException("DNS opcode and response code must fit four bits")
    }
    if (actualQuestions != questionCount) {
        throw IllegalArgumentException("DNS question count does not match the owned questions")
    }
    if (headerOnly) {
        if (actualRecords != 0) { throw IllegalArgumentException("DNS header-only summary must not own records") }
    } else if (actualRecords != answerCount + authorityCount + additionalCount) {
        throw IllegalArgumentException("DNS record counts do not match the ordered records")
    }
}

private func dnsMalformed(message: String): Nothing {
    throw api.ResolveException(api.ResolveErrorCode.SystemFailure, message)
}

private func dnsInvalidName(message: String): Nothing {
    throw api.ResolveException(api.ResolveErrorCode.InvalidName, message)
}
