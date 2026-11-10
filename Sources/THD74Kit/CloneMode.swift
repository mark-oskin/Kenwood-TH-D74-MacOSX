import Foundation

public enum CloneError: Error, CustomStringConvertible {
    case enterRefused(reply: String)
    case badBlockHeader(block: Int, header: [UInt8])
    case missingAck(block: Int)
    case writeRefused(block: Int, reply: [UInt8])
    case protectedBlock(Int)
    case verifyFailed(block: Int)

    public var description: String {
        func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
        switch self {
        case .enterRefused(let r): return "The radio would not enter programming mode (replied \"\(r)\")"
        case .badBlockHeader(let b, let h): return "Unexpected header for block \(b): \(hex(h))"
        case .missingAck(let b): return "No acknowledgement after block \(b)"
        case .writeRefused(let b, let r): return "The radio did not accept block \(b) (replied \(r.isEmpty ? "nothing" : hex(r)))"
        case .protectedBlock(let b): return "Block \(b) is outside the area this tool is allowed to write"
        case .verifyFailed(let b): return "Block \(b) read back differently from what was written"
        }
    }
}

public enum MemoryProgress: Sendable {
    case reading(done: Int, total: Int)
    case writing(done: Int, total: Int)
    case verifying(done: Int, total: Int)
}

extension Radio {
    /// Blocks this tool will write. Like CHIRP, it never writes the last two
    /// blocks of the image.
    public static let writableBlocks = 0..<(MemoryImage.blockCount - 2)

    /// Runs `body` with the radio in clone ("MCP") programming mode. The
    /// radio is always told to leave programming mode afterwards, which
    /// makes it restart.
    private func withProgrammingMode<T>(_ body: () throws -> T) throws -> T {
        let reply = try raw("0M PROGRAM")
        guard reply == "0M" else { throw CloneError.enterRefused(reply: reply) }
        defer {
            try? transport.write([UInt8(ascii: "E")])
            // Let the exit command reach the radio before the link is closed.
            transport.drain(for: 0.5)
            try? transport.setBaudRate(9600)
        }
        try transport.setBaudRate(57600)
        transport.drain(for: 0.3)
        return try body()
    }

    /// Reads part of the radio's memory. Nothing is written.
    public func readMemory(
        blocks: Range<Int> = MemoryImage.channelBlocks,
        progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) throws -> MemoryImage {
        try withProgrammingMode {
            var image = MemoryImage()
            for (index, block) in blocks.enumerated() {
                image.setBlock(block, try readBlock(block))
                progress(index + 1, blocks.count)
            }
            return image
        }
    }

    /// Changes the radio's memory in a single programming session:
    /// reads `blocks`, lets `edit` modify that image, writes only the blocks
    /// that now differ, then reads those blocks back to confirm them.
    ///
    /// Returns the image as it now is on the radio and the blocks written.
    @discardableResult
    public func updateMemory(
        blocks: Range<Int> = MemoryImage.channelBlocks,
        progress: (MemoryProgress) -> Void = { _ in },
        edit: (inout MemoryImage) throws -> Void
    ) throws -> (image: MemoryImage, written: [Int]) {
        try withProgrammingMode {
            var current = MemoryImage()
            for (index, block) in blocks.enumerated() {
                current.setBlock(block, try readBlock(block))
                progress(.reading(done: index + 1, total: blocks.count))
            }

            var edited = current
            try edit(&edited)

            let changed = (0..<MemoryImage.blockCount).filter { edited.block($0) != current.block($0) }
            for block in changed where !blocks.contains(block) || !Self.writableBlocks.contains(block) {
                throw CloneError.protectedBlock(block)
            }

            for (index, block) in changed.enumerated() {
                try writeBlock(block, edited.block(block))
                progress(.writing(done: index + 1, total: changed.count))
            }
            for (index, block) in changed.enumerated() {
                guard try readBlock(block) == edited.block(block) else {
                    throw CloneError.verifyFailed(block: block)
                }
                progress(.verifying(done: index + 1, total: changed.count))
            }
            return (edited, changed)
        }
    }

    private func readBlock(_ block: Int) throws -> [UInt8] {
        let hi = UInt8(block >> 8), lo = UInt8(block & 0xFF)
        try transport.write([UInt8(ascii: "R"), hi, lo, 0, 0])
        let header = try transport.read(count: 5, timeout: 3)
        guard header[0] == UInt8(ascii: "W"), header[1] == hi, header[2] == lo else {
            throw CloneError.badBlockHeader(block: block, header: header)
        }
        let data = try transport.read(count: MemoryImage.blockSize, timeout: 5)
        try transport.write([0x06])
        guard try transport.read(count: 1, timeout: 3) == [0x06] else {
            throw CloneError.missingAck(block: block)
        }
        return data
    }

    private func writeBlock(_ block: Int, _ data: [UInt8]) throws {
        precondition(data.count == MemoryImage.blockSize)
        guard Self.writableBlocks.contains(block) else { throw CloneError.protectedBlock(block) }
        // A length of 0 means a full 256-byte block.
        try transport.write([UInt8(ascii: "W"), UInt8(block >> 8), UInt8(block & 0xFF), 0, 0] + data)
        let reply = (try? transport.read(count: 1, timeout: 5)) ?? []
        guard reply == [0x06] else { throw CloneError.writeRefused(block: block, reply: reply) }
    }
}
