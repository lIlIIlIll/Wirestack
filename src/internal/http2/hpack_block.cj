package wirestack.internal.http2

import std.collection.ArrayList

public class HpackFieldEncoding {
    public let field: HpackHeaderField
    public let mode: HpackIndexingMode

    public init(field: HpackHeaderField, mode!: HpackIndexingMode = HpackIndexingMode.Incremental) {
        this.field = field
        this.mode = if (field.sensitive) { HpackIndexingMode.NeverIndexed } else { mode }
    }
}

/** Stateful HPACK decoder. One instance is owned by one HTTP/2 connection. */
public class HpackDecoder {
    private let limits: Http2Limits
    private let table: HpackDynamicTable

    public init(limits!: Http2Limits = Http2Limits()) {
        this.limits = limits
        table = HpackDynamicTable(UInt64(limits.maxHeaderTableBytes))
    }

    public func updateAllowedTableCapacity(value: UInt64): Unit { table.updateAllowedCapacity(value) }

    public func decode(block: Array<Byte>): Array<HpackHeaderField> {
        if (UInt64(block.size) > UInt64(limits.maxHeaderBlockBytes)) {
            throw HpackException("HPACK block exceeds the configured compressed limit")
        }
        let fields = ArrayList<HpackHeaderField>()
        var listBytes = 0u64
        var cursor: Int64 = 0
        var sawHeader = false
        while (cursor < block.size) {
            let first = block[cursor]
            if ((first & 0x80u8) != 0u8) {
                let indexed = decodeHpackInteger(block, cursor, 7u8)
                if (indexed.value == 0u64) { throw HpackException("HPACK indexed field cannot use index zero") }
                let field = table.get(indexed.value)
                appendDecodedField(fields, field, listBytes)
                listBytes += field.tableSize
                cursor = indexed.nextOffset
                sawHeader = true
            } else if ((first & 0x40u8) != 0u8) {
                let decoded = decodeLiteral(block, cursor, 6u8, HpackIndexingMode.Incremental)
                appendDecodedField(fields, decoded.field, listBytes)
                listBytes += decoded.field.tableSize
                let _ = table.record(decoded.field, HpackIndexingMode.Incremental)
                cursor = decoded.nextOffset
                sawHeader = true
            } else if ((first & 0x20u8) != 0u8) {
                if (sawHeader) { throw HpackException("HPACK table size update must precede every header field") }
                let update = decodeHpackInteger(block, cursor, 5u8)
                table.setCapacity(update.value)
                cursor = update.nextOffset
            } else {
                let mode = if ((first & 0x10u8) != 0u8) {
                    HpackIndexingMode.NeverIndexed
                } else {
                    HpackIndexingMode.WithoutIndexing
                }
                let decoded = decodeLiteral(block, cursor, 4u8, mode)
                appendDecodedField(fields, decoded.field, listBytes)
                listBytes += decoded.field.tableSize
                cursor = decoded.nextOffset
                sawHeader = true
            }
        }
        fields.toArray()
    }

    public func dynamicEntry(index: UInt64): HpackHeaderField { table.get(index) }

    private func decodeLiteral(
        block: Array<Byte>,
        offset: Int64,
        prefixBits: UInt8,
        mode: HpackIndexingMode
    ): DecodedLiteral {
        let nameIndex = decodeHpackInteger(block, offset, prefixBits)
        var cursor = nameIndex.nextOffset
        let name = if (nameIndex.value == 0u64) {
            let decodedName = decodeHpackString(
                block,
                cursor,
                UInt64(limits.maxHeaderListBytes),
                maxEncodedBytes: UInt64(limits.maxHeaderBlockBytes)
            )
            cursor = decodedName.nextOffset
            hpackUtf8(decodedName.bytes, "name")
        } else {
            table.get(nameIndex.value).name
        }
        if (cursor >= block.size) { throw HpackException("HPACK literal value is missing") }
        let decodedValue = decodeHpackString(
            block,
            cursor,
            UInt64(limits.maxHeaderListBytes),
            maxEncodedBytes: UInt64(limits.maxHeaderBlockBytes)
        )
        let sensitive = isNeverIndexed(mode)
        DecodedLiteral(
            HpackHeaderField(name, hpackUtf8(decodedValue.bytes, "value"), sensitive: sensitive),
            decodedValue.nextOffset
        )
    }

    private func appendDecodedField(
        fields: ArrayList<HpackHeaderField>,
        field: HpackHeaderField,
        currentBytes: UInt64
    ): Unit {
        if (UInt64(fields.size) >= UInt64(limits.maxHeaderFields)) {
            throw HpackException("HPACK header count exceeds the configured limit")
        }
        if (field.tableSize > UInt64(limits.maxHeaderListBytes) - min(currentBytes, UInt64(limits.maxHeaderListBytes))) {
            throw HpackException("HPACK header list exceeds the configured limit")
        }
        fields.add(field)
    }
}

/** Stateful HPACK encoder paired with one peer decoder. */
public class HpackEncoder {
    private let limits: Http2Limits
    private let table: HpackDynamicTable
    private var pendingCapacity: ?UInt64 = None<UInt64>

    public init(limits!: Http2Limits = Http2Limits()) {
        this.limits = limits
        table = HpackDynamicTable(UInt64(limits.maxHeaderTableBytes))
    }

    public func updatePeerTableCapacity(value: UInt64): Unit {
        table.updateAllowedCapacity(value)
        table.setCapacity(value)
        pendingCapacity = Some(value)
    }

    public func encode(fields: Array<HpackFieldEncoding>): Array<Byte> {
        validateEncodeList(fields)
        let output = ArrayList<Byte>()
        if (let Some(value) <- pendingCapacity) {
            appendEncoded(output, encodeHpackInteger(value, 5u8, prefix: 0x20u8))
            pendingCapacity = None<UInt64>
        }
        for (encodedField in fields) {
            encodeField(output, encodedField)
            if (UInt64(output.size) > UInt64(limits.maxHeaderBlockBytes)) {
                throw HpackException("encoded HPACK block exceeds the configured compressed limit")
            }
        }
        output.toArray()
    }

    private func encodeField(output: ArrayList<Byte>, encoded: HpackFieldEncoding): Unit {
        let field = encoded.field
        if (!isNeverIndexed(encoded.mode)) {
            if (let Some(index) <- table.findExact(field.name, field.value)) {
                appendEncoded(output, encodeHpackInteger(index, 7u8, prefix: 0x80u8))
                return
            }
        }
        let nameIndex = match (table.findName(field.name)) {
            case Some(value) => value
            case None => 0u64
        }
        match (encoded.mode) {
            case HpackIndexingMode.Incremental =>
                appendEncoded(output, encodeLiteral(field, nameIndex, 6u8, 0x40u8))
                let _ = table.record(field, HpackIndexingMode.Incremental)
            case HpackIndexingMode.WithoutIndexing =>
                appendEncoded(output, encodeLiteral(field, nameIndex, 4u8, 0x00u8))
            case HpackIndexingMode.NeverIndexed =>
                appendEncoded(output, encodeLiteral(field, nameIndex, 4u8, 0x10u8))
        }
    }

    private func encodeLiteral(
        field: HpackHeaderField,
        nameIndex: UInt64,
        prefixBits: UInt8,
        prefix: Byte
    ): Array<Byte> {
        let output = ArrayList<Byte>()
        appendEncoded(output, encodeHpackInteger(nameIndex, prefixBits, prefix: prefix))
        if (nameIndex == 0u64) { appendEncoded(output, bestString(field.name.toArray())) }
        appendEncoded(output, bestString(field.value.toArray()))
        output.toArray()
    }

    private func bestString(value: Array<Byte>): Array<Byte> {
        let raw = encodeHpackString(value, maxEncodedBytes: UInt64(limits.maxHeaderBlockBytes))
        let huffman = encodeHpackString(
            value, huffman: true, maxEncodedBytes: UInt64(limits.maxHeaderBlockBytes)
        )
        if (huffman.size < raw.size) { huffman } else { raw }
    }

    private func validateEncodeList(fields: Array<HpackFieldEncoding>): Unit {
        if (UInt64(fields.size) > UInt64(limits.maxHeaderFields)) {
            throw HpackException("HPACK header count exceeds the configured limit")
        }
        var bytes = 0u64
        for (encoded in fields) {
            let size = encoded.field.tableSize
            if (size > UInt64(limits.maxHeaderListBytes) - min(bytes, UInt64(limits.maxHeaderListBytes))) {
                throw HpackException("HPACK header list exceeds the configured limit")
            }
            bytes += size
        }
    }
}

private class DecodedLiteral {
    let field: HpackHeaderField
    let nextOffset: Int64
    init(field: HpackHeaderField, nextOffset: Int64) { this.field = field; this.nextOffset = nextOffset }
}

private func appendEncoded(output: ArrayList<Byte>, bytes: Array<Byte>): Unit {
    for (octet in bytes) { output.add(octet) }
}

private func hpackUtf8(bytes: Array<Byte>, kind: String): String {
    try {
        String.fromUtf8(bytes)
    } catch (_: IllegalArgumentException) {
        throw HpackException("HPACK literal ${kind} is not valid UTF-8")
    }
}

private func isNeverIndexed(mode: HpackIndexingMode): Bool {
    match (mode) { case HpackIndexingMode.NeverIndexed => true; case _ => false }
}
