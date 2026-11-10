import Foundation
import Testing
@testable import THD74Kit

/// Replays canned replies, recording what was sent.
final class FakeTransport: RadioTransport {
    var replies: [String]
    var sent: [String] = []
    init(_ replies: [String]) { self.replies = replies }

    func write(_ bytes: [UInt8]) throws {
        sent.append(String(decoding: bytes, as: UTF8.self))
    }
    func readUntil(_ terminator: UInt8, timeout: TimeInterval) throws -> [UInt8] {
        guard !replies.isEmpty else { throw SerialError.timeout(partial: "") }
        return Array(replies.removeFirst().utf8)
    }
    func read(count: Int, timeout: TimeInterval) throws -> [UInt8] {
        throw SerialError.timeout(partial: "")
    }
}

// Captured from a real TH-D74 (firmware 1.06).
let aprsLine = "ME 000,0144390000,0000600000,0,0,0,0,1,0,0,0,0,0,0,0,08,08,000,0,CQCQCQ,0,00,0"

@Test func parsesRealChannel() throws {
    let ch = try Channel(meReply: aprsLine)
    #expect(ch.number == 0)
    #expect(ch.frequency == 144_390_000)
    #expect(ch.offset == 600_000)
    #expect(ch.mode == .fm)
    #expect(ch.shift == .simplex)
    #expect(ch.toneMode == .none)
    #expect(ch.txFrequency == 144_390_000)
    #expect(ch.toneHz == 88.5)
    #expect(ch.urcall == "CQCQCQ")
}

@Test(arguments: [
    aprsLine,
    "ME 010,0145370000,0000600000,0,0,0,0,1,0,0,0,0,0,0,2,08,08,000,0,CQCQCQ,0,00,0",
    "ME 002,0146520000,0000600000,0,0,0,0,1,1,0,0,0,0,0,0,12,08,000,0,CQCQCQ,0,00,0",
    "ME 999,0440000000,0005000000,A,B,6,1,3,0,0,1,0,1,0,1,49,00,103,3,W1AW   A,2,99,1",
])
func roundTrips(line: String) throws {
    #expect(try Channel(meReply: line).meCommand == line)
}

@Test func derivesShiftAndTone() throws {
    let down = try Channel(meReply: "ME 010,0145370000,0000600000,0,0,0,0,1,0,0,0,0,0,0,2,08,08,000,0,CQCQCQ,0,00,0")
    #expect(down.txFrequency == 144_770_000)

    let tone = try Channel(meReply: "ME 002,0146520000,0000600000,0,0,0,0,1,1,0,0,0,0,0,0,12,08,000,0,CQCQCQ,0,00,0")
    #expect(tone.toneMode == .tone)
    #expect(tone.toneHz == 100.0)

    let split = try Channel(meReply: "ME 003,0145990000,0435800000,0,0,0,0,1,0,0,0,0,0,1,3,08,08,000,0,CQCQCQ,0,00,0")
    #expect(split.isSplit)
    #expect(split.txFrequency == 435_800_000)
}

@Test func rejectsMalformedReplies() {
    #expect(throws: ChannelParseError.self) { try Channel(meReply: "ME 000,0144390000") }
    #expect(throws: ChannelParseError.self) {
        try Channel(meReply: aprsLine.replacingOccurrences(of: ",08,08,", with: ",77,08,"))
    }
}

@Test func radioReadsChannelsAndEmptySlots() throws {
    let fake = FakeTransport([aprsLine, "N"])
    let radio = Radio(transport: fake)
    #expect(try radio.readChannel(0)?.frequency == 144_390_000)
    #expect(try radio.readChannel(1) == nil)
    #expect(fake.sent == ["ME 000\r", "ME 001\r"])
}

@Test func radioReportsRejectedCommands() {
    let radio = Radio(transport: FakeTransport(["?"]))
    #expect(throws: RadioError.self) { try radio.model() }
}

@Test func decodesChannelFromMemoryImage() throws {
    var image = MemoryImage()
    for block in MemoryImage.channelBlocks { image.setBlock(block, [UInt8](repeating: 0xFF, count: 256)) }

    // Channel 8 is the third slot of the second 256-byte group.
    var flags = [UInt8](repeating: 0xFF, count: 256)
    flags.replaceSubrange(32..<36, with: [0x00, 0x01, 0x03, 0xFF])
    image.setBlock(0x20, flags)

    var group = [UInt8](repeating: 0xFF, count: 256)
    var m = [UInt8](repeating: 0, count: 40)
    m.replaceSubrange(0..<4, with: [0x88, 0x9F, 0x94, 0x1B])   // 462.725 MHz
    m.replaceSubrange(4..<8, with: [0x40, 0x4B, 0x4C, 0x00])   // 5 MHz
    m[8] = 0x88; m[9] = 0x01; m[10] = 0x81; m[11] = 22; m[12] = 8
    m.replaceSubrange(15..<23, with: Array("CQCQCQ  ".utf8))
    group.replaceSubrange(80..<120, with: m)
    image.setBlock(0x41, group)

    var names = [UInt8](repeating: 0xFF, count: 256)
    names.replaceSubrange(128..<144, with: Array("Lakeshore".utf8) + [UInt8](repeating: 0, count: 7))
    image.setBlock(0x100, names)

    let stored = try #require(try image.channel(8))
    #expect(stored.name == "Lakeshore")
    #expect(stored.group == 3)
    #expect(stored.channel.meCommand ==
        "ME 008,0462725000,0005000000,8,8,0,0,1,1,0,0,0,0,0,1,22,08,000,0,CQCQCQ,0,00,1")
    #expect(try image.channel(9) == nil)
    #expect(throws: ImageError.self) { try MemoryImage().channel(0) }
}

@Test func encodingChannelsIntoImage() throws {
    var image = MemoryImage()
    for block in MemoryImage.channelBlocks { image.setBlock(block, [UInt8](repeating: 0xFF, count: 256)) }

    var ch = Channel(number: 42, frequency: 444_025_000, offset: 5_000_000, stepCode: 8, txStepCode: 8)
    ch.shift = .up
    ch.toneMode = .tone
    ch.toneCode = 13
    ch.lockout = true
    let stored = StoredChannel(channel: ch, name: "Lakeshore W1ABC", group: 2)

    try image.setChannel(42, stored)
    #expect(try image.channel(42) == stored)
    #expect(try image.channel(41) == nil)

    // Bytes match what the radio itself stores for the same channel.
    let at = 0x4000 + (42 / 6) * 256 + (42 % 6) * 40
    let expected: [UInt8] = [0xA8, 0x48, 0x77, 0x1A, 0x40, 0x4B, 0x4C, 0x00, 0x88, 0x01, 0x81, 0x0D, 0x08, 0x00, 0x0C]
        + Array("CQCQCQ".utf8) + [0, 0] + Array("DIRECT".utf8) + [0, 0] + Array("DIRECT".utf8) + [0, 0, 0]
    #expect(Array(image.bytes[at..<at + 40]) == expected)
    #expect(Array(image.bytes[0x2000 + 42 * 4..<0x2000 + 42 * 4 + 4]) == [0x02, 0x01, 0x02, 0xFF])

    // Re-storing an unchanged channel changes nothing; clearing empties the slot.
    let before = image.bytes
    try image.setChannel(42, try image.channel(42))
    #expect(image.bytes == before)
    try image.setChannel(42, nil)
    #expect(try image.channel(42) == nil)
    #expect(Array(image.bytes[at..<at + 40]) == [UInt8](repeating: 0xFF, count: 40))
}

@Test func toneModeSetterIsExclusive() {
    var ch = Channel(number: 0, frequency: 146_520_000)
    ch.toneMode = .ctcss
    ch.toneMode = .dcs
    #expect(!ch.toneOn && !ch.ctcssOn && ch.dcsOn && !ch.crossOn)
    ch.toneMode = .none
    #expect(ch.toneMode == .none)
}

/// Runs only when a local backup of a real radio is present (backups are not
/// checked in): re-encoding every channel must reproduce the radio's bytes.
@Test func reencodingRealBackupIsLossless() throws {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("backups")
    let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "bin" }
    for file in files {
        let original = try MemoryImage(bytes: Array(try Data(contentsOf: file)))
        var copy = original
        for n in Radio.channelRange { try copy.setChannel(n, try original.channel(n)) }
        #expect(copy.bytes == original.bytes, "\(file.lastPathComponent)")
    }
}

/// A stand-in radio that speaks the clone-mode protocol over a byte array.
final class FakeCloneRadio: RadioTransport {
    var memory: [UInt8]
    var inProgrammingMode = false
    var exited = false
    var blocksWritten: [Int] = []
    /// Simulates flash that silently fails to take a write.
    var dropWritesToBlock: Int?
    private var input: [UInt8] = []
    private var output: [UInt8] = []

    init(memory: [UInt8]) { self.memory = memory }

    func write(_ bytes: [UInt8]) throws {
        input += bytes
        while true {
            if !inProgrammingMode {
                guard let end = input.firstIndex(of: 0x0D) else { return }
                let line = String(decoding: input[..<end], as: UTF8.self)
                input.removeFirst(end + 1)
                if line == "0M PROGRAM" { inProgrammingMode = true; output += Array("0M\r".utf8) }
                else { output += Array("?\r".utf8) }
                continue
            }
            guard let op = input.first else { return }
            switch op {
            case UInt8(ascii: "E"):
                input.removeFirst(); inProgrammingMode = false; exited = true
            case 0x06:
                input.removeFirst(); output.append(0x06)
            case UInt8(ascii: "R"):
                guard input.count >= 5 else { return }
                let block = Int(input[1]) << 8 | Int(input[2])
                input.removeFirst(5)
                output += [UInt8(ascii: "W"), UInt8(block >> 8), UInt8(block & 0xFF), 0, 0]
                output += memory[block * 256..<(block + 1) * 256]
            case UInt8(ascii: "W"):
                guard input.count >= 5 + 256 else { return }
                let block = Int(input[1]) << 8 | Int(input[2])
                if block != dropWritesToBlock {
                    memory.replaceSubrange(block * 256..<(block + 1) * 256, with: input[5..<261])
                }
                blocksWritten.append(block)
                input.removeFirst(261)
                output.append(0x06)
            default:
                input.removeFirst()
            }
        }
    }

    func readUntil(_ terminator: UInt8, timeout: TimeInterval) throws -> [UInt8] {
        guard let end = output.firstIndex(of: terminator) else { throw SerialError.timeout(partial: "") }
        defer { output.removeFirst(end + 1) }
        return Array(output[..<end])
    }

    func read(count: Int, timeout: TimeInterval) throws -> [UInt8] {
        guard output.count >= count else { throw SerialError.timeout(partial: "") }
        defer { output.removeFirst(count) }
        return Array(output[..<count])
    }
}

func emptyRadioMemory() -> [UInt8] {
    var memory = [UInt8](repeating: 0xFF, count: MemoryImage.size)
    for n in 0..<1200 { memory.replaceSubrange(0x2000 + n * 4..<0x2000 + n * 4 + 4, with: [0xFF, 0x00, UInt8(n / 100), 0xFF]) }
    memory.replaceSubrange(0x10000..<0x10000 + 1200 * 16, with: [UInt8](repeating: 0, count: 1200 * 16))
    return memory
}

@Test func updateWritesOnlyChangedBlocksAndVerifies() throws {
    let fake = FakeCloneRadio(memory: emptyRadioMemory())
    let radio = Radio(transport: fake)
    let before = fake.memory

    var ch = Channel(number: 7, frequency: 146_520_000)
    ch.toneMode = .tone
    let stored = StoredChannel(channel: ch, name: "Simplex", group: 0)
    let result = try radio.updateMemory { try $0.setChannel(7, stored) }

    // One flags block, one channel-data block, one names block.
    #expect(result.written == [0x20, 0x41, 0x100])
    #expect(fake.blocksWritten == [0x20, 0x41, 0x100])
    #expect(fake.exited)
    #expect(try MemoryImage(bytes: fake.memory).channel(7) == stored)

    // Everything outside those three blocks is untouched.
    for block in 0..<MemoryImage.blockCount where ![0x20, 0x41, 0x100].contains(block) {
        #expect(fake.memory[block * 256..<(block + 1) * 256] == before[block * 256..<(block + 1) * 256])
    }
}

@Test func updateWithNoChangesWritesNothing() throws {
    let fake = FakeCloneRadio(memory: emptyRadioMemory())
    let result = try Radio(transport: fake).updateMemory { _ in }
    #expect(result.written.isEmpty && fake.blocksWritten.isEmpty && fake.exited)
}

@Test func updateDetectsFailedWriteAndStillExits() throws {
    let fake = FakeCloneRadio(memory: emptyRadioMemory())
    fake.dropWritesToBlock = 0x100
    let stored = StoredChannel(channel: Channel(number: 0, frequency: 146_520_000), name: "Test")
    #expect(throws: CloneError.self) {
        try Radio(transport: fake).updateMemory { try $0.setChannel(0, stored) }
    }
    #expect(fake.exited)
}

@Test func updateRefusesToWriteOutsideTheBlocksItRead() throws {
    let fake = FakeCloneRadio(memory: emptyRadioMemory())
    #expect(throws: CloneError.self) {
        try Radio(transport: fake).updateMemory { $0.setBlock(0x05, [UInt8](repeating: 0, count: 256)) }
    }
    #expect(fake.blocksWritten.isEmpty && fake.exited)
}

@Test func parsesChirpCSV() throws {
    let csv = #"""
    Location,Name,Frequency,Duplex,Offset,Tone,rToneFreq,cToneFreq,DtcsCode,DtcsPolarity,RxDtcsCode,CrossMode,Mode,TStep,Skip,Power,Comment,URCALL,RPT1CALL,RPT2CALL,DVCODE
    0,Fairview W1AAA,443.225000,+,5.000000,Tone,103.5,88.5,023,NN,023,Tone->Tone,FM,25.00,,,"W1AAA; Fairview, XX; Open; FM; 17.41 mi NE",,,,
    1,Riverton,146.450000,+,1.000000,DTCS,88.5,88.5,245,NN,023,Tone->Tone,NFM,5.00,S,,"W1BBB; said ""hi""",,,,
    2,Hilltop W1CCC,145.125000,split,223.240000,TSQL,110.9,114.8,023,NN,023,Tone->Tone,FM,5.00,,,,,,,
    3,Bay Island W1DDD,147.012500,+,0.600000,,88.5,88.5,023,NN,023,Tone->Tone,FM,5.00,,,,,,,
    4,Bad tone,146.000000,,0.600000,Tone,99.9,88.5,023,NN,023,Tone->Tone,FM,5.00,,,,,,,
    5,Too high,927.000000,-,25.000000,,88.5,88.5,023,NN,023,Tone->Tone,FM,5.00,,,,,,,

    """#
    let result = try ChirpCSV.parse(csv)
    #expect(result.channels.count == 4)
    #expect(result.skipped.map(\.line) == [6, 7])

    let first = result.channels[0]
    #expect(first.stored.name == "Fairview W1AAA")
    #expect(first.stored.channel.frequency == 443_225_000)
    #expect(first.stored.channel.shift == .up && first.stored.channel.offset == 5_000_000)
    #expect(first.stored.channel.toneMode == .tone && first.stored.channel.toneHz == 103.5)
    #expect(first.stored.channel.stepCode == 8)
    #expect(first.comment == "W1AAA; Fairview, XX; Open; FM; 17.41 mi NE")
    #expect(first.distanceMiles == 17.41)

    let dcs = result.channels[1].stored.channel
    #expect(dcs.toneMode == .dcs && dcs.dcsNumber == 245 && dcs.mode == .nfm && dcs.lockout)
    #expect(result.channels[1].comment == "W1BBB; said \"hi\"")

    let split = result.channels[2].stored.channel
    #expect(split.isSplit && split.txFrequency == 223_240_000)
    #expect(split.toneMode == .ctcss && split.ctcssHz == 114.8)

    // 147.0125 is not on the 5 kHz grid, so it gets a 12.5 kHz step.
    #expect(result.channels[3].stored.channel.stepCode == 5)

    #expect(throws: ChirpCSVError.self) { try ChirpCSV.parse("a,b\n1,2\n") }
    // Windows line endings, a byte-order mark, and a comma inside quotes.
    #expect(ChirpCSV.parseRecords("\u{FEFF}a,b\r\n\"x, y\",2\r\n") == [["a", "b"], ["x, y", "2"]])
}

@Test func groupNamesRoundTrip() throws {
    var image = MemoryImage()
    for block in MemoryImage.channelBlocks { image.setBlock(block, [UInt8](repeating: 0, count: 256)) }
    try image.setGroupName(1, "Near home")
    #expect(try image.groupName(1) == "Near home")
    #expect(try image.groupName(2) == "")
    #expect(Array(image.bytes[0x14810..<0x14819]) == Array("Near home".utf8))
}
