import Foundation

/// A channel read from an import file: everything but its slot number.
public struct ImportedChannel: Identifiable, Equatable, Sendable {
    /// Position in the file, starting at 0.
    public let id: Int
    public var stored: StoredChannel
    public var comment: String
    /// Distance from the search point, when the comment carries one
    /// (as files made from RepeaterBook searches do: "17.41 mi NE").
    public var distanceMiles: Double?
}

public enum ChirpCSVError: Error, CustomStringConvertible {
    case missingColumns([String])
    case empty

    public var description: String {
        switch self {
        case .missingColumns(let names): "This does not look like a CHIRP CSV file (no \(names.joined(separator: " or ")) column)."
        case .empty: "The file has no rows."
        }
    }
}

/// Reads the CSV format used by CHIRP, which most repeater sources can export.
public enum ChirpCSV {
    public struct Result: Sendable {
        public var channels: [ImportedChannel]
        /// Rows that could not be used, with the reason.
        public var skipped: [(line: Int, reason: String)]
    }

    public static func parse(_ text: String) throws -> Result {
        var records = parseRecords(text)
        records.removeAll { $0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard let header = records.first else { throw ChirpCSVError.empty }
        var column: [String: Int] = [:]
        for (index, name) in header.enumerated() { column[name.trimmingCharacters(in: .whitespaces)] = index }
        guard column["Frequency"] != nil else { throw ChirpCSVError.missingColumns(["Frequency"]) }

        var result = Result(channels: [], skipped: [])
        for (offset, record) in records.dropFirst().enumerated() {
            func field(_ name: String) -> String {
                guard let i = column[name], i < record.count else { return "" }
                return record[i].trimmingCharacters(in: .whitespaces)
            }
            do {
                let stored = try channel(from: field)
                let comment = field("Comment")
                result.channels.append(ImportedChannel(
                    id: result.channels.count, stored: stored, comment: comment, distanceMiles: distance(in: comment)))
            } catch let reason as RowProblem {
                result.skipped.append((line: offset + 2, reason: reason.text))
            }
        }
        return result
    }

    private struct RowProblem: Error { let text: String }

    private static func hertz(_ text: String) -> Int? {
        guard let mhz = Double(text), mhz >= 0 else { return nil }
        return Int((mhz * 1_000_000).rounded())
    }

    private static func toneCode(_ text: String) -> Int? {
        guard let hz = Double(text) else { return nil }
        return Tables.tones.firstIndex { abs($0 - hz) < 0.05 }
    }

    private static func channel(from field: (String) -> String) throws -> StoredChannel {
        guard let frequency = hertz(field("Frequency")), frequency > 0 else {
            throw RowProblem(text: "no usable frequency (\"\(field("Frequency"))\")")
        }
        guard (100_000...524_000_000).contains(frequency) else {
            throw RowProblem(text: "\(field("Frequency")) MHz is outside the radio's range")
        }
        var ch = Channel(number: 0, frequency: frequency)
        ch.stepCode = Tables.stepCode(forFrequency: frequency)
        ch.txStepCode = ch.stepCode

        let modes: [String: Mode] = ["FM": .fm, "NFM": .nfm, "AM": .am, "DV": .dv, "LSB": .lsb,
                                     "USB": .usb, "CW": .cw, "WFM": .wfm, "DR": .dr, "": .fm]
        guard let mode = modes[field("Mode").uppercased()] else {
            throw RowProblem(text: "mode \(field("Mode")) is not one the radio has")
        }
        ch.mode = mode

        let offset = hertz(field("Offset")) ?? 0
        switch field("Duplex").lowercased() {
        case "+": ch.shift = .up; ch.offset = offset
        case "-": ch.shift = .down; ch.offset = offset
        case "split": ch.shift = .split; ch.oddSplit = true; ch.offset = offset
        case "", "off": ch.offset = frequency >= 300_000_000 ? 5_000_000 : 600_000
        default: throw RowProblem(text: "duplex \"\(field("Duplex"))\" not understood")
        }

        func tone(_ name: String) throws -> Int {
            guard let code = toneCode(field(name)) else {
                throw RowProblem(text: "tone \(field(name)) Hz is not one the radio has")
            }
            return code
        }
        func dcs(_ name: String) throws -> Int {
            guard let number = Int(field(name)), let code = Tables.dcsCodes.firstIndex(of: number) else {
                throw RowProblem(text: "DCS code \(field(name)) is not one the radio has")
            }
            return code
        }
        switch field("Tone").uppercased() {
        case "":
            break
        case "TONE":
            ch.toneMode = .tone
            ch.toneCode = try tone("rToneFreq")
        case "TSQL":
            ch.toneMode = .ctcss
            ch.ctcssCode = try tone("cToneFreq")
        case "DTCS":
            ch.toneMode = .dcs
            ch.dcsCode = try dcs("DtcsCode")
        case "CROSS":
            ch.toneMode = .cross
            switch field("CrossMode") {
            case "DTCS->": ch.crossMode = .dcsOff; ch.dcsCode = try dcs("DtcsCode")
            case "Tone->DTCS": ch.crossMode = .toneDCS; ch.toneCode = try tone("rToneFreq"); ch.dcsCode = try dcs("RxDtcsCode")
            case "DTCS->Tone": ch.crossMode = .dcsCTCSS; ch.dcsCode = try dcs("DtcsCode"); ch.ctcssCode = try tone("cToneFreq")
            case "Tone->Tone": ch.crossMode = .toneCTCSS; ch.toneCode = try tone("rToneFreq"); ch.ctcssCode = try tone("cToneFreq")
            default: throw RowProblem(text: "cross mode \"\(field("CrossMode"))\" is not one the radio has")
            }
        default:
            throw RowProblem(text: "tone mode \"\(field("Tone"))\" not understood")
        }

        ch.lockout = field("Skip").uppercased() == "S"
        if !field("URCALL").isEmpty { ch.urcall = String(field("URCALL").prefix(8)) }

        let name = String(field("Name").unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }.map(Character.init).prefix(16))
        return StoredChannel(
            channel: ch, name: name, group: 0,
            rpt1: field("RPT1CALL").isEmpty ? "DIRECT" : String(field("RPT1CALL").prefix(8)),
            rpt2: field("RPT2CALL").isEmpty ? "DIRECT" : String(field("RPT2CALL").prefix(8)))
    }

    /// Finds "17.41 mi" in a comment.
    static func distance(in comment: String) -> Double? {
        guard let match = comment.firstMatch(of: /(\d+(?:\.\d+)?)\s*mi\b/) else { return nil }
        return Double(match.1)
    }

    /// Splits CSV text into records and fields, honouring quoted fields.
    static func parseRecords(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var quoted = false
        var sawAnything = false
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" { field.unicodeScalars.append("\""); i += 1 }
                    else { quoted = false }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else if c == "\"" {
                quoted = true
                sawAnything = true
            } else if c == "," {
                record.append(field); field = ""
                sawAnything = true
            } else if c == "\n" || c == "\r" {
                if c == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                if sawAnything || !field.isEmpty { record.append(field); records.append(record) }
                record = []; field = ""; sawAnything = false
            } else {
                field.unicodeScalars.append(c)
            }
            i += 1
        }
        if sawAnything || !field.isEmpty { record.append(field); records.append(record) }
        return records
    }
}
