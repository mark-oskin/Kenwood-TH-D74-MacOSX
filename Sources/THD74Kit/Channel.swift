import Foundation

public enum ChannelParseError: Error, CustomStringConvertible {
    case fieldCount(Int)
    case badField(index: Int, value: String)

    public var description: String {
        switch self {
        case .fieldCount(let n): "Expected 23 fields in ME reply, got \(n)"
        case .badField(let i, let v): "Bad value \"\(v)\" in ME field \(i)"
        }
    }
}

public enum Mode: Int, CaseIterable, Sendable {
    case fm, dv, am, lsb, usb, cw, nfm, dr, wfm, rcw

    public var label: String {
        ["FM", "DV", "AM", "LSB", "USB", "CW", "NFM", "DR", "WFM", "R-CW"][rawValue]
    }
}

public enum Shift: Int, CaseIterable, Sendable {
    case simplex, up, down, split

    public var label: String { ["", "+", "-", "split"][rawValue] }
}

public enum CrossMode: Int, CaseIterable, Sendable {
    case dcsOff, toneDCS, dcsCTCSS, toneCTCSS

    public var label: String { ["DCS/Off", "Tone/DCS", "DCS/CTCSS", "Tone/CTCSS"][rawValue] }
}

public enum DStarSquelch: Int, CaseIterable, Sendable {
    case off, code, callsign
}

/// How the channel uses sub-audible signalling. The radio stores four
/// separate on/off flags; at most one is expected to be on.
public enum ToneMode: Equatable, Sendable, CaseIterable {
    case none, tone, ctcss, dcs, cross
}

public enum Tables {
    /// CTCSS / tone frequencies in Hz, indexed by the radio's code.
    public static let tones: [Double] = [
        67.0, 69.3, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4, 88.5, 91.5,
        94.8, 97.4, 100.0, 103.5, 107.2, 110.9, 114.8, 118.8, 123.0, 127.3,
        131.8, 136.5, 141.3, 146.2, 151.4, 156.7, 159.8, 162.2, 165.5, 167.9,
        171.3, 173.8, 177.3, 179.9, 183.5, 186.2, 189.9, 192.8, 196.6, 199.5,
        203.5, 206.5, 210.7, 218.1, 225.7, 229.1, 233.6, 241.8, 250.3, 254.1,
    ]

    /// DCS codes, indexed by the radio's code.
    public static let dcsCodes: [Int] = [
        23, 25, 26, 31, 32, 36, 43, 47, 51, 53, 54, 65, 71, 72, 73, 74, 114, 115, 116, 122,
        125, 131, 132, 134, 143, 145, 152, 155, 156, 162, 165, 172, 174, 205, 212, 223, 225,
        226, 243, 244, 245, 246, 251, 252, 255, 261, 263, 265, 266, 271, 274, 306, 311, 315,
        325, 331, 332, 343, 346, 351, 356, 364, 365, 371, 411, 412, 413, 423, 431, 432, 445,
        446, 452, 454, 455, 462, 464, 465, 466, 503, 506, 516, 523, 526, 532, 546, 565, 606,
        612, 624, 627, 631, 632, 654, 662, 664, 703, 712, 723, 731, 732, 734, 743, 754,
    ]

    /// Tuning step sizes in Hz, indexed by the radio's (hex digit) code.
    public static let steps: [Double] = [
        5000, 6250, 8330, 9000, 10000, 12500, 15000, 20000, 25000, 30000, 50000, 100000,
    ]

    /// A sensible step code for a frequency: the band's usual step (5 kHz
    /// below 300 MHz, 25 kHz above) when the frequency sits on that grid,
    /// otherwise the first finer step that it does sit on.
    public static func stepCode(forFrequency hz: Int) -> Int {
        let usual = hz >= 300_000_000 ? 8 : 0
        for code in [usual, 5, 1, 0] where hz % Int(steps[code]) == 0 { return code }
        return usual
    }

    /// Fine-tuning step sizes in Hz.
    public static let fineSteps: [Int] = [20, 100, 500, 1000]
}

/// One memory channel, as carried by the `ME` command (23 fields).
///
/// Fields are kept as the radio's own codes so that a channel read from the
/// radio renders back to exactly the same string. Channel names are not part
/// of `ME`; they are only reachable through the clone-mode memory image.
public struct Channel: Equatable, Sendable {
    public var number: Int               // p1
    public var frequency: Int            // p2, Hz
    public var offset: Int               // p3, Hz (the TX frequency when split)
    public var stepCode: Int             // p4
    public var txStepCode: Int           // p5
    public var mode: Mode                // p6
    public var fineMode: Bool            // p7
    public var fineStepCode: Int         // p8
    public var toneOn: Bool              // p9
    public var ctcssOn: Bool             // p10
    public var dcsOn: Bool               // p11
    public var crossOn: Bool             // p12
    public var reverse: Bool             // p13
    public var oddSplit: Bool            // p14
    public var shift: Shift              // p15
    public var toneCode: Int             // p16
    public var ctcssCode: Int            // p17
    public var dcsCode: Int              // p18
    public var crossMode: CrossMode      // p19
    public var urcall: String            // p20
    public var dstarSquelch: DStarSquelch // p21
    public var dstarSquelchCode: Int     // p22
    public var lockout: Bool             // p23

    public init(
        number: Int, frequency: Int, offset: Int = 600_000, stepCode: Int = 0, txStepCode: Int = 0,
        mode: Mode = .fm, fineMode: Bool = false, fineStepCode: Int = 1,
        toneOn: Bool = false, ctcssOn: Bool = false, dcsOn: Bool = false, crossOn: Bool = false,
        reverse: Bool = false, oddSplit: Bool = false, shift: Shift = .simplex,
        toneCode: Int = 8, ctcssCode: Int = 8, dcsCode: Int = 0, crossMode: CrossMode = .dcsOff,
        urcall: String = "CQCQCQ", dstarSquelch: DStarSquelch = .off, dstarSquelchCode: Int = 0,
        lockout: Bool = false
    ) {
        self.number = number; self.frequency = frequency; self.offset = offset
        self.stepCode = stepCode; self.txStepCode = txStepCode; self.mode = mode
        self.fineMode = fineMode; self.fineStepCode = fineStepCode
        self.toneOn = toneOn; self.ctcssOn = ctcssOn; self.dcsOn = dcsOn; self.crossOn = crossOn
        self.reverse = reverse; self.oddSplit = oddSplit; self.shift = shift
        self.toneCode = toneCode; self.ctcssCode = ctcssCode; self.dcsCode = dcsCode
        self.crossMode = crossMode; self.urcall = urcall
        self.dstarSquelch = dstarSquelch; self.dstarSquelchCode = dstarSquelchCode
        self.lockout = lockout
    }

    /// Parses a full reply line such as `ME 000,0144390000,...`.
    public init(meReply: String) throws {
        var body = Substring(meReply)
        if body.hasPrefix("ME ") { body = body.dropFirst(3) }
        let f = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 23 else { throw ChannelParseError.fieldCount(f.count) }

        func int(_ i: Int, radix: Int = 10) throws -> Int {
            guard let v = Int(f[i - 1], radix: radix), v >= 0 else {
                throw ChannelParseError.badField(index: i, value: f[i - 1])
            }
            return v
        }
        func flag(_ i: Int) throws -> Bool {
            switch f[i - 1] {
            case "0": return false
            case "1": return true
            default: throw ChannelParseError.badField(index: i, value: f[i - 1])
            }
        }
        func code<T: RawRepresentable>(_ i: Int, _: T.Type) throws -> T where T.RawValue == Int {
            guard let v = T(rawValue: try int(i)) else {
                throw ChannelParseError.badField(index: i, value: f[i - 1])
            }
            return v
        }
        func index(_ i: Int, below limit: Int, radix: Int = 10) throws -> Int {
            let v = try int(i, radix: radix)
            guard v < limit else { throw ChannelParseError.badField(index: i, value: f[i - 1]) }
            return v
        }

        number = try int(1)
        frequency = try int(2)
        offset = try int(3)
        stepCode = try index(4, below: Tables.steps.count, radix: 16)
        txStepCode = try index(5, below: Tables.steps.count, radix: 16)
        mode = try code(6, Mode.self)
        fineMode = try flag(7)
        fineStepCode = try index(8, below: Tables.fineSteps.count)
        toneOn = try flag(9)
        ctcssOn = try flag(10)
        dcsOn = try flag(11)
        crossOn = try flag(12)
        reverse = try flag(13)
        oddSplit = try flag(14)
        shift = try code(15, Shift.self)
        toneCode = try index(16, below: Tables.tones.count)
        ctcssCode = try index(17, below: Tables.tones.count)
        dcsCode = try index(18, below: Tables.dcsCodes.count)
        crossMode = try code(19, CrossMode.self)
        urcall = f[19]
        dstarSquelch = try code(21, DStarSquelch.self)
        dstarSquelchCode = try int(22)
        lockout = try flag(23)
    }

    /// The `ME` command that would write this channel to the radio.
    public var meCommand: String {
        func b(_ v: Bool) -> String { v ? "1" : "0" }
        func hex(_ v: Int) -> String { String(v, radix: 16, uppercase: true) }
        return "ME " + [
            String(format: "%03d", number),
            String(format: "%010d", frequency),
            String(format: "%010d", offset),
            hex(stepCode), hex(txStepCode), String(mode.rawValue),
            b(fineMode), String(fineStepCode),
            b(toneOn), b(ctcssOn), b(dcsOn), b(crossOn), b(reverse), b(oddSplit),
            String(shift.rawValue),
            String(format: "%02d", toneCode),
            String(format: "%02d", ctcssCode),
            String(format: "%03d", dcsCode),
            String(crossMode.rawValue),
            urcall,
            String(dstarSquelch.rawValue),
            String(format: "%02d", dstarSquelchCode),
            b(lockout),
        ].joined(separator: ",")
    }

    // MARK: Derived values

    public var toneMode: ToneMode {
        get {
            if toneOn { return .tone }
            if ctcssOn { return .ctcss }
            if dcsOn { return .dcs }
            if crossOn { return .cross }
            return .none
        }
        set {
            toneOn = newValue == .tone
            ctcssOn = newValue == .ctcss
            dcsOn = newValue == .dcs
            crossOn = newValue == .cross
        }
    }

    public var isSplit: Bool { oddSplit || shift == .split }

    public var txFrequency: Int {
        if isSplit { return offset }
        switch shift {
        case .up: return frequency + offset
        case .down: return frequency - offset
        default: return frequency
        }
    }

    public var toneHz: Double { Tables.tones[toneCode] }
    public var ctcssHz: Double { Tables.tones[ctcssCode] }
    public var dcsNumber: Int { Tables.dcsCodes[dcsCode] }
    public var stepHz: Double { Tables.steps[stepCode] }
    public var isDigital: Bool { mode == .dv || mode == .dr }
}
