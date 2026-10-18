package wirestack.gzip

import wirestack.*

private let gzipCodeOrder: Array<Int64> = [16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15]
private let gzipLengthBase: Array<Int64> = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258]
private let gzipLengthExtra: Array<Int64> = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0]
private let gzipDistanceBase: Array<Int64> = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577]
private let gzipDistanceExtra: Array<Int64> = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13]

// Canonical tables use bounded counts and sorted symbols, not a 2^15 lookup table.
private class GzipHuffman {
    var counts = Array<Int64>(16, repeat: 0)
    var symbols = Array<Int64>(288, repeat: 0)
    var offsets = Array<Int64>(16, repeat: 0)
    func release(): Unit {
        counts = Array<Int64>(); symbols = Array<Int64>(); offsets = Array<Int64>()
    }
}

internal class GzipPullDecoder {
    private let source: HttpBodyStream
    private let limits: GzipLimits
    private let check: () -> Unit
    private var input: Array<Byte>
    private var probe = Array<Byte>(1, repeat: 0)
    private var window = Array<Byte>(32768, repeat: 0)
    private var lengths = Array<Int64>(320, repeat: 0)
    private var crcTable = Array<UInt32>(256, repeat: 0)
    private let literal = GzipHuffman()
    private let distance = GzipHuffman()
    private let codeLength = GzipHuffman()
    private var fixedTables = false
    private var inputAt: Int64 = 0
    private var inputEnd: Int64 = 0
    private var wireEof = false
    private var bitValue: UInt32 = 0
    private var bitCount: Int64 = 0
    private var state: Int64 = 0 // header, block, stored, codes, trailer, next, EOF
    private var finalBlock = false
    private var storedLeft: Int64 = 0
    private var matchLeft: Int64 = 0
    private var matchDistance: Int64 = 0
    private var history: Int64 = 0
    private var windowAt: Int64 = 0
    private var crc: UInt32 = 0xffffffff
    private var headerCrc: UInt32 = 0xffffffff
    private var headerBytes: Int64 = 0
    private var memberSize: UInt32 = 0
    private var blocks: Int64 = 0
    private var work: Int64 = 0
    internal var encodedBytesRead: Int64 = 0
    internal var decodedBytes: Int64 = 0
    internal var memberCount: Int64 = 0
    internal var validatedEof = false
    internal var maximumWorkBetweenChecks: Int64 = 0

    internal init(source: HttpBodyStream, limits: GzipLimits, check: () -> Unit) {
        this.source = source; this.limits = limits; this.check = check
        input = Array<Byte>(min(limits.inputBufferBytes, limits.maximumEncodedBytes), repeat: 0)
        check()
        for (index in 0..256) {
            var value = UInt32(index)
            for (_ in 0..8) {
                step()
                value = if ((value & 1) != 0) { (value >> 1) ^ 0xedb88320 } else { value >> 1 }
            }
            crcTable[index] = value
        }
    }

    private func step(): Unit {
        work++
        maximumWorkBetweenChecks = max(maximumWorkBetweenChecks, work)
        if (work == 512) { checkpoint() }
    }
    private func checkpoint(): Unit { work = 0; check() }
    private func fail(code: GzipErrorCode): Nothing { throw GzipException(code, "gzip decode failed") }
    private func updateCrc(value: UInt32, byte: Byte): UInt32 {
        (value >> 8) ^ crcTable[Int64((value ^ UInt32(byte)) & 255)]
    }
    private func nextByte(): Int64 {
        step()
        if (inputAt == inputEnd) {
            if (wireEof) { return -1 }
            checkpoint()
            let remaining = limits.maximumEncodedBytes - encodedBytesRead
            if (remaining == 0) {
                let count = source.read(probe)
                if (count == 0) { wireEof = true; return -1 }
                if (count != 1) { fail(GzipErrorCode.InvalidDeflate) }
                encodedBytesRead++
                fail(GzipErrorCode.InputLimit)
            }
            if (input.size > remaining) { input = probe }
            inputEnd = source.read(input); inputAt = 0
            if (inputEnd < 0 || inputEnd > input.size) { fail(GzipErrorCode.InvalidDeflate) }
            encodedBytesRead += inputEnd
            if (inputEnd == 0) { wireEof = true; return -1 }
        }
        let value = Int64(input[inputAt]); inputAt++; value
    }
    private func byte(): Byte {
        let value = nextByte()
        if (value < 0) { fail(GzipErrorCode.UnexpectedEof) }
        UInt8(UInt64(value))
    }
    private func bits(count: Int64): Int64 {
        while (bitCount < count) { bitValue |= UInt32(byte()) << bitCount; bitCount += 8 }
        let result = Int64(bitValue & ((1u32 << count) - 1))
        bitValue = bitValue >> count; bitCount -= count; result
    }
    private func align(): Unit { bitValue = 0; bitCount = 0 }
    private func headerByte(): Byte {
        if (headerBytes == limits.maximumHeaderBytes) { fail(GzipErrorCode.HeaderLimit) }
        let value = byte(); headerBytes++; headerCrc = updateCrc(headerCrc, value); value
    }
    private func header(first!: Int64 = -1): Unit {
        if (memberCount == limits.maximumMembers) { fail(GzipErrorCode.MemberLimit) }
        headerBytes = 0; headerCrc = 0xffffffff
        let magic = if (first < 0) { headerByte() } else {
            if (limits.maximumHeaderBytes < 1) { fail(GzipErrorCode.HeaderLimit) }
            headerBytes = 1; headerCrc = updateCrc(headerCrc, UInt8(UInt64(first))); UInt8(UInt64(first))
        }
        if (magic != 31) { fail(GzipErrorCode.InvalidHeader) }
        if (headerByte() != 139) {
            fail(if (first < 0) { GzipErrorCode.InvalidHeader } else { GzipErrorCode.TrailingData })
        }
        if (headerByte() != 8) { fail(GzipErrorCode.InvalidHeader) }
        let flags = headerByte()
        if ((flags & 0xe0) != 0) { fail(GzipErrorCode.InvalidHeader) }
        for (_ in 0..6) { let _ = headerByte() }
        if ((flags & 4) != 0) {
            let low = Int64(headerByte()); let size = low | (Int64(headerByte()) << 8)
            for (_ in 0..size) { let _ = headerByte() }
        }
        if ((flags & 8) != 0) { while (headerByte() != 0) {} }
        if ((flags & 16) != 0) { while (headerByte() != 0) {} }
        if ((flags & 2) != 0) {
            let expected = Int64((headerCrc ^ 0xffffffff) & 65535)
            let low = Int64(headerByte()); let actual = low | (Int64(headerByte()) << 8)
            if (actual != expected) { fail(GzipErrorCode.ChecksumMismatch) }
        }
        memberCount++; history = 0; windowAt = 0; memberSize = 0; crc = 0xffffffff
        state = 1
    }
    private func build(tree: GzipHuffman, start: Int64, count: Int64, complete: Bool): Unit {
        for (index in 0..16) { step(); tree.counts[index] = 0; tree.offsets[index] = 0 }
        var maximum: Int64 = 0
        for (index in 0..count) {
            step(); let length = lengths[start + index]
            if (length < 0 || length > 15) { fail(GzipErrorCode.InvalidDeflate) }
            tree.counts[length]++; maximum = max(maximum, length)
        }
        var left: Int64 = 1
        for (length in 1..16) {
            step(); left = (left << 1) - tree.counts[length]
            if (left < 0) { fail(GzipErrorCode.InvalidDeflate) }
        }
        // RFC1951 permits a single one-bit symbol for literal/distance trees,
        // and a zero-symbol distance tree for a literal-only block.
        if (left != 0 && (complete || maximum > 1)) { fail(GzipErrorCode.InvalidDeflate) }
        for (length in 1..15) { step(); tree.offsets[length + 1] = tree.offsets[length] + tree.counts[length] }
        for (index in 0..count) {
            step(); let length = lengths[start + index]
            if (length != 0) { tree.symbols[tree.offsets[length]] = index; tree.offsets[length]++ }
        }
    }
    private func symbol(tree: GzipHuffman): Int64 {
        var code: Int64 = 0; var first: Int64 = 0; var index: Int64 = 0
        for (length in 1..16) {
            step(); code |= bits(1)
            let count = tree.counts[length]
            if (code >= first && code - first < count) { return tree.symbols[index + code - first] }
            index += count; first = (first + count) << 1; code <<= 1
        }
        fail(GzipErrorCode.InvalidDeflate)
    }
    private func fixed(): Unit {
        if (fixedTables) { return }
        for (index in 0..288) {
            step(); lengths[index] = if (index < 144) { 8 } else if (index < 256) { 9 } else if (index < 280) { 7 } else { 8 }
        }
        build(literal, 0, 288, true)
        for (index in 0..32) { step(); lengths[index] = 5 }
        build(distance, 0, 32, true)
        fixedTables = true
    }
    private func dynamic(): Unit {
        fixedTables = false
        let literals = bits(5) + 257; let distances = bits(5) + 1; let codes = bits(4) + 4
        if (literals > 286) { fail(GzipErrorCode.InvalidDeflate) }
        for (index in 0..19) { step(); lengths[index] = 0 }
        for (index in 0..codes) { step(); lengths[gzipCodeOrder[index]] = bits(3) }
        build(codeLength, 0, 19, true)
        var index: Int64 = 0
        while (index < literals + distances) {
            step(); let value = symbol(codeLength)
            if (value < 16) { lengths[index] = value; index++; continue }
            var repeat: Int64 = 0; var length: Int64 = 0
            if (value == 16) {
                if (index == 0) { fail(GzipErrorCode.InvalidDeflate) }
                repeat = bits(2) + 3; length = lengths[index - 1]
            } else if (value == 17) { repeat = bits(3) + 3 }
            else if (value == 18) { repeat = bits(7) + 11 }
            else { fail(GzipErrorCode.InvalidDeflate) }
            if (repeat > literals + distances - index) { fail(GzipErrorCode.InvalidDeflate) }
            for (_ in 0..repeat) { step(); lengths[index] = length; index++ }
        }
        if (lengths[256] == 0) { fail(GzipErrorCode.InvalidDeflate) }
        build(literal, 0, literals, false); build(distance, literals, distances, false)
    }
    private func block(): Unit {
        step()
        if (blocks == limits.maximumBlocks) { fail(GzipErrorCode.BlockLimit) }
        blocks++; finalBlock = bits(1) == 1
        let kind = bits(2)
        if (kind == 0) {
            align(); let low = Int64(byte()); storedLeft = low | (Int64(byte()) << 8)
            let inverseLow = Int64(byte()); let inverse = inverseLow | (Int64(byte()) << 8)
            if ((storedLeft ^ inverse) != 65535) { fail(GzipErrorCode.InvalidDeflate) }
            state = 2
        } else if (kind == 1) { fixed(); state = 3 }
        else if (kind == 2) { dynamic(); state = 3 }
        else { fail(GzipErrorCode.InvalidDeflate) }
    }
    private func emit(destination: Array<Byte>, index: Int64, value: Byte): Unit {
        step()
        if (decodedBytes == limits.maximumDecodedBytes) { fail(GzipErrorCode.OutputLimit) }
        destination[index] = value; window[windowAt] = value
        windowAt = (windowAt + 1) & 32767; history = min(32768, history + 1)
        decodedBytes++; memberSize = memberSize + 1; crc = updateCrc(crc, value)
    }
    private func little32(): UInt32 {
        var value: UInt32 = 0
        for (index in 0..4) { value |= UInt32(byte()) << (index * 8) }
        value
    }
    internal func read(destination: Array<Byte>): Int64 {
        checkpoint()
        let capacity = min(destination.size, limits.maximumReadBytes)
        var produced: Int64 = 0
        while (produced < capacity && !validatedEof) {
            step()
            if (state == 0) { header(); continue }
            if (state == 1) { block(); continue }
            if (state == 2) {
                if (storedLeft == 0) { state = if (finalBlock) { 4 } else { 1 }; continue }
                emit(destination, produced, byte()); produced++; storedLeft--; continue
            }
            if (state == 3) {
                if (matchLeft > 0) {
                    emit(destination, produced, window[(windowAt - matchDistance + 32768) & 32767])
                    produced++; matchLeft--; continue
                }
                let value = symbol(literal)
                if (value < 256) { emit(destination, produced, UInt8(UInt64(value))); produced++; continue }
                if (value == 256) { state = if (finalBlock) { 4 } else { 1 }; continue }
                if (value > 285) { fail(GzipErrorCode.InvalidDeflate) }
                matchLeft = gzipLengthBase[value - 257] + bits(gzipLengthExtra[value - 257])
                let dist = symbol(distance)
                if (dist > 29) { fail(GzipErrorCode.InvalidDeflate) }
                matchDistance = gzipDistanceBase[dist] + bits(gzipDistanceExtra[dist])
                if (matchDistance > history) { fail(GzipErrorCode.InvalidDeflate) }
                continue
            }
            if (state == 4) {
                align()
                if (little32() != (crc ^ 0xffffffff)) { fail(GzipErrorCode.ChecksumMismatch) }
                if (little32() != memberSize) { fail(GzipErrorCode.SizeMismatch) }
                state = 5; continue
            }
            if (state == 5) {
                let first = nextByte()
                if (first < 0) { validatedEof = true; state = 6; continue }
                if (first != 31) { fail(GzipErrorCode.TrailingData) }
                header(first: first); continue
            }
        }
        checkpoint(); produced
    }
    internal func release(): Unit {
        input = Array<Byte>(); probe = Array<Byte>(); window = Array<Byte>()
        lengths = Array<Int64>(); crcTable = Array<UInt32>()
        literal.release(); distance.release(); codeLength.release()
    }
}

