import Foundation

public enum ImageError: Error, CustomStringConvertible {
    case wrongSize(Int)
    case notLoaded(offset: Int)

    public var description: String {
        switch self {
        case .wrongSize(let n): "Memory image is \(n) bytes, expected \(MemoryImage.size)"
        case .notLoaded(let o): String(format: "Memory image does not include offset 0x%05X", o)
        }
    }
}

/// A memory channel as stored in the radio's memory image, which carries
/// more than the live `ME` command does (name, group, D-STAR repeaters).
public struct StoredChannel: Equatable, Sendable {
    public var channel: Channel
    public var name: String
    public var group: Int
    public var rpt1: String
    public var rpt2: String

    public init(channel: Channel, name: String = "", group: Int = 0, rpt1: String = "DIRECT", rpt2: String = "DIRECT") {
        self.channel = channel; self.name = name; self.group = group; self.rpt1 = rpt1; self.rpt2 = rpt2
    }
}

/// The radio's programmable memory as read in clone ("MCP") mode.
///
/// Layout, from the CHIRP driver (little-endian), with two corrections:
/// the TX step is the whole low nibble of byte 8 (checked against a real
/// radio), and the mode is read as the whole high nibble of byte 9 so that
/// WFM and R-CW fit (not yet checked against a radio).
/// - 0x02000: 1200 × 4-byte flags (used, lockout, group)
/// - 0x04000: channels, 40 bytes each, in groups of 6 padded to 256 bytes
/// - 0x10000: 1200 × 16-byte names
public struct MemoryImage: Sendable {
    public static let size = 0x7A300
    public static let blockSize = 256
    public static let blockCount = size / blockSize

    /// The blocks holding channel flags, channel data and names.
    public static let channelBlocks = 0x20..<0x14B

    static let flagsOffset = 0x2000
    static let channelsOffset = 0x4000
    static let namesOffset = 0x10000
    static let channelSize = 40

    public private(set) var bytes: [UInt8]
    /// Which 256-byte blocks actually hold data from the radio.
    public private(set) var loadedBlocks: IndexSet

    public init() {
        bytes = [UInt8](repeating: 0xFF, count: Self.size)
        loadedBlocks = IndexSet()
    }

    /// Wraps a complete image previously saved with `bytes`.
    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.size else { throw ImageError.wrongSize(bytes.count) }
        self.bytes = bytes
        loadedBlocks = IndexSet(integersIn: 0..<Self.blockCount)
    }

    public mutating func setBlock(_ block: Int, _ data: [UInt8]) {
        precondition(data.count == Self.blockSize && block < Self.blockCount)
        bytes.replaceSubrange(block * Self.blockSize..<(block + 1) * Self.blockSize, with: data)
        loadedBlocks.insert(block)
    }

    /// The 256 bytes of one block.
    public func block(_ block: Int) -> [UInt8] {
        Array(bytes[block * Self.blockSize..<(block + 1) * Self.blockSize])
    }

    private func check(_ range: Range<Int>) throws {
        for block in range.lowerBound / Self.blockSize...(range.upperBound - 1) / Self.blockSize
        where !loadedBlocks.contains(block) {
            throw ImageError.notLoaded(offset: block * Self.blockSize)
        }
    }

    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        let printable = bytes.prefix { $0 != 0 && $0 != 0xFF }
        return String(decoding: printable, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Decodes memory channel `number` (0-999). Returns nil if the slot is empty.
    public func channel(_ number: Int) throws -> StoredChannel? {
        precondition(Radio.channelRange.contains(number))
        let flagAt = Self.flagsOffset + number * 4
        let dataAt = Self.channelsOffset + (number / 6) * 256 + (number % 6) * Self.channelSize
        let nameAt = Self.namesOffset + number * 16
        try check(flagAt..<flagAt + 4)
        try check(dataAt..<dataAt + Self.channelSize)
        try check(nameAt..<nameAt + 16)

        let flags = bytes[flagAt..<flagAt + 4]
        guard flags[flagAt] != 0xFF else { return nil }

        let m = Array(bytes[dataAt..<dataAt + Self.channelSize])
        func u32(_ i: Int) -> Int {
            Int(m[i]) | Int(m[i + 1]) << 8 | Int(m[i + 2]) << 16 | Int(m[i + 3]) << 24
        }
        func bits(_ byte: Int, _ shift: Int, _ width: Int) -> Int {
            (Int(m[byte]) >> shift) & ((1 << width) - 1)
        }
        func clamp(_ v: Int, _ limit: Int) -> Int { min(v, limit - 1) }

        let split = bits(10, 2, 1) == 1
        let channel = Channel(
            number: number,
            frequency: u32(0),
            offset: u32(4),
            stepCode: clamp(bits(8, 4, 4), Tables.steps.count),
            txStepCode: clamp(bits(8, 0, 4), Tables.steps.count),
            mode: Mode(rawValue: bits(9, 4, 4)) ?? .fm,
            fineMode: bits(9, 2, 1) == 1,
            fineStepCode: bits(9, 0, 2),
            toneOn: bits(10, 7, 1) == 1,
            ctcssOn: bits(10, 6, 1) == 1,
            dcsOn: bits(10, 5, 1) == 1,
            crossOn: bits(10, 4, 1) == 1,
            reverse: false,
            oddSplit: split,
            shift: Shift(rawValue: bits(10, 0, 2)) ?? .simplex,
            toneCode: clamp(Int(m[11]), Tables.tones.count),
            ctcssCode: clamp(bits(12, 0, 6), Tables.tones.count),
            dcsCode: clamp(bits(13, 0, 7), Tables.dcsCodes.count),
            crossMode: CrossMode(rawValue: bits(14, 4, 2)) ?? .dcsOff,
            urcall: Self.text(m[15..<23]),
            dstarSquelch: DStarSquelch(rawValue: bits(14, 0, 2)) ?? .off,
            dstarSquelchCode: bits(39, 0, 7),
            lockout: flags[flagAt + 1] & 1 == 1
        )
        return StoredChannel(
            channel: channel,
            name: Self.text(bytes[nameAt..<nameAt + 16]),
            group: Int(flags[flagAt + 2]),
            rpt1: Self.text(m[23..<31]),
            rpt2: Self.text(m[31..<39])
        )
    }

    /// True when every block came from the radio (or a full backup file),
    /// so the image is safe to save as a complete backup.
    public var isComplete: Bool { loadedBlocks.count == Self.blockCount }

    /// A fresh FM channel as the radio itself stores one.
    private static let blankChannel: [UInt8] =
        [0, 0, 0, 0, 0xC0, 0x27, 0x09, 0x00, 0x00, 0x01, 0x00, 0x08, 0x08, 0x00, 0x0C]
        + Array("CQCQCQ".utf8) + [0, 0] + Array("DIRECT".utf8) + [0, 0] + Array("DIRECT".utf8) + [0, 0] + [0]

    /// The first flag byte doubles as "in use" and a band code. Observed on
    /// a US radio: 0 for 2 m, 1 for 1.25 m, 2 for 70 cm, 0xFF for empty.
    /// Values for frequencies outside the three ham bands are a guess.
    static func bandCode(forFrequency hz: Int) -> UInt8 {
        switch hz {
        case ..<200_000_000: 0
        case ..<300_000_000: 1
        default: 2
        }
    }

    private static func field(_ text: String, width: Int) -> [UInt8] {
        let ascii = text.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }.map { UInt8($0.value) }
        return Array(ascii.prefix(width)) + [UInt8](repeating: 0, count: max(0, width - ascii.count))
    }

    /// The radio has 30 memory groups, numbered 0-29. Their names are stored
    /// after the channel names.
    public static let groupCount = 30
    private static let groupNameIndex = 1152

    public func groupName(_ group: Int) throws -> String {
        precondition((0..<Self.groupCount).contains(group))
        let at = Self.namesOffset + (Self.groupNameIndex + group) * 16
        try check(at..<at + 16)
        return Self.text(bytes[at..<at + 16])
    }

    public mutating func setGroupName(_ group: Int, _ name: String) throws {
        precondition((0..<Self.groupCount).contains(group))
        let at = Self.namesOffset + (Self.groupNameIndex + group) * 16
        try check(at..<at + 16)
        bytes.replaceSubrange(at..<at + 16, with: Self.field(name, width: 16))
    }

    /// The memory group slot `number` belongs to, whether or not it is in use.
    public func group(ofSlot number: Int) throws -> Int {
        let flagAt = Self.flagsOffset + number * 4
        try check(flagAt..<flagAt + 4)
        return Int(bytes[flagAt + 2])
    }

    /// Stores `stored` in slot `number`, or clears the slot when nil.
    /// Bits whose meaning is unknown are left as they were.
    public mutating func setChannel(_ number: Int, _ stored: StoredChannel?) throws {
        precondition(Radio.channelRange.contains(number))
        let flagAt = Self.flagsOffset + number * 4
        let dataAt = Self.channelsOffset + (number / 6) * 256 + (number % 6) * Self.channelSize
        let nameAt = Self.namesOffset + number * 16
        try check(flagAt..<flagAt + 4)
        try check(dataAt..<dataAt + Self.channelSize)
        try check(nameAt..<nameAt + 16)

        guard let stored else {
            // An empty slot keeps its group (by default, the hundreds digit).
            bytes[flagAt] = 0xFF
            bytes[flagAt + 1] &= 0xFE
            bytes.replaceSubrange(dataAt..<dataAt + Self.channelSize, with: [UInt8](repeating: 0xFF, count: Self.channelSize))
            bytes.replaceSubrange(nameAt..<nameAt + 16, with: [UInt8](repeating: 0, count: 16))
            return
        }

        let ch = stored.channel
        let wasUsed = bytes[flagAt] != 0xFF
        var m = wasUsed ? Array(bytes[dataAt..<dataAt + Self.channelSize]) : Self.blankChannel
        func put32(_ i: Int, _ v: Int) {
            m[i] = UInt8(v & 0xFF); m[i + 1] = UInt8(v >> 8 & 0xFF)
            m[i + 2] = UInt8(v >> 16 & 0xFF); m[i + 3] = UInt8(v >> 24 & 0xFF)
        }
        func put(_ byte: Int, _ shift: Int, _ width: Int, _ value: Int) {
            let mask = UInt8(((1 << width) - 1) << shift)
            m[byte] = (m[byte] & ~mask) | (UInt8(value << shift) & mask)
        }
        put32(0, ch.frequency)
        put32(4, ch.offset)
        put(8, 4, 4, ch.stepCode)
        put(8, 0, 4, ch.txStepCode)
        put(9, 4, 4, ch.mode.rawValue)
        put(9, 2, 1, ch.fineMode ? 1 : 0)
        put(9, 0, 2, ch.fineStepCode)
        put(10, 7, 1, ch.toneOn ? 1 : 0)
        put(10, 6, 1, ch.ctcssOn ? 1 : 0)
        put(10, 5, 1, ch.dcsOn ? 1 : 0)
        put(10, 4, 1, ch.crossOn ? 1 : 0)
        put(10, 2, 1, ch.oddSplit ? 1 : 0)
        put(10, 0, 2, ch.shift.rawValue)
        m[11] = UInt8(ch.toneCode)
        put(12, 0, 6, ch.ctcssCode)
        put(13, 0, 7, ch.dcsCode)
        put(14, 4, 2, ch.crossMode.rawValue)
        put(14, 0, 2, ch.dstarSquelch.rawValue)
        m.replaceSubrange(15..<23, with: Self.field(ch.urcall, width: 8))
        m.replaceSubrange(23..<31, with: Self.field(stored.rpt1, width: 8))
        m.replaceSubrange(31..<39, with: Self.field(stored.rpt2, width: 8))
        put(39, 0, 7, ch.dstarSquelchCode)
        bytes.replaceSubrange(dataAt..<dataAt + Self.channelSize, with: m)

        let previous = Array(bytes[flagAt..<flagAt + 4])
        var flags: [UInt8] = wasUsed ? previous : [0x00, 0x00, 0x00, 0xFF]
        flags[0] = Self.bandCode(forFrequency: ch.frequency)
        flags[1] = (flags[1] & 0xFE) | (ch.lockout ? 1 : 0)
        flags[2] = UInt8(clamping: stored.group)
        bytes.replaceSubrange(flagAt..<flagAt + 4, with: flags)
        bytes.replaceSubrange(nameAt..<nameAt + 16, with: Self.field(stored.name, width: 16))
    }

    /// All in-use memory channels.
    public func channels() throws -> [StoredChannel] {
        try Radio.channelRange.compactMap { try channel($0) }
    }
}
