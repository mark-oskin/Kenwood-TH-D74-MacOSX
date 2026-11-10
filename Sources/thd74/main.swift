import Foundation
import THD74Kit

let usage = """
usage: thd74 [--port bluetooth|<device path>] <command>

commands:
  info                 Show model and firmware version
  dump [first-last]    List memory channels using live commands (no names)
  clone <file> [--full] [--check]
                       Read the radio's memory in programming mode, save it
                       to <file>, and list channels with names. --full reads
                       everything, not just the channel area. --check also
                       compares every channel against the live commands.
  show <file>          List the channels in a saved memory file
  rename <ch> <name>   WRITES to the radio: set one channel's name
  restore <file>       WRITES to the radio: make its memory match a full
                       backup file (only differing blocks are written)
  raw <command>        Send one raw command and print the reply
  ports                List ways the radio can currently be reached

If --port is omitted, a USB connection is used when present, otherwise
the paired radio over Bluetooth.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
    let fill = String(repeating: " ", count: max(0, width - s.count))
    return right ? fill + s : s + fill
}

func mhz(_ hz: Int) -> String { String(format: "%.6f", Double(hz) / 1_000_000) }

func toneColumn(_ ch: Channel) -> String {
    switch ch.toneMode {
    case .none: ""
    case .tone: String(format: "T %.1f", ch.toneHz)
    case .ctcss: String(format: "CT %.1f", ch.ctcssHz)
    case .dcs: String(format: "DCS %03d", ch.dcsNumber)
    case .cross: "X " + ch.crossMode.label
    }
}

func offsetColumn(_ ch: Channel) -> String {
    if ch.isSplit { return "tx " + mhz(ch.offset) }
    switch ch.shift {
    case .up: return "+" + String(format: "%.3f", Double(ch.offset) / 1_000_000)
    case .down: return "-" + String(format: "%.3f", Double(ch.offset) / 1_000_000)
    default: return ""
    }
}

func showProgress(_ progress: MemoryProgress) {
    let text: String
    switch progress {
    case .reading(let done, let total): text = "Reading \(done)/\(total)   "
    case .writing(let done, let total): text = "Writing \(done)/\(total)   "
    case .verifying(let done, let total): text = "Verifying \(done)/\(total) "
    }
    FileHandle.standardError.write(Data(("\r" + text).utf8))
}

func printStored(_ stored: [StoredChannel]) {
    print([pad("Ch", 3), pad("Name", 16), pad("Frequency", 11, right: true), pad("Offset", 14),
           pad("Mode", 4), pad("Tone", 12), pad("Grp", 3), "Flags"].joined(separator: "  "))
    for s in stored {
        let ch = s.channel
        print([pad(String(format: "%03d", ch.number), 3), pad(s.name, 16),
               pad(mhz(ch.frequency), 11, right: true), pad(offsetColumn(ch), 14),
               pad(ch.mode.label, 4), pad(toneColumn(ch), 12), pad(String(s.group), 3),
               ch.lockout ? "lockout" : ""].joined(separator: "  "))
    }
    print("\(stored.count) channels in use.")
}

var args = Array(CommandLine.arguments.dropFirst())
var portPath: String?
if let i = args.firstIndex(of: "--port") {
    guard i + 1 < args.count else { fail(usage) }
    portPath = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
guard let command = args.first else { fail(usage) }

if command == "ports" {
    var ports = SerialPort.usbCandidatePorts().map { "\($0)  (USB)" }
    ports += BluetoothTransport.pairedRadios().map { "bluetooth  (paired: \($0.name ?? "TH-D74"))" }
    print(ports.isEmpty ? "No TH-D74 found over USB or among paired Bluetooth devices." : ports.joined(separator: "\n"))
    exit(0)
}

func connect(_ portPath: String?) throws -> Radio {
    if let path = portPath, path != "bluetooth" { return try Radio.connect(path: path) }
    if portPath == nil, let usb = SerialPort.usbCandidatePorts().first { return try Radio.connect(path: usb) }
    return try Radio.connect(transport: try BluetoothTransport.openFirstPaired())
}

do {
    switch command {
    case "info":
        let radio = try connect(portPath)
        print("Model:    \(try radio.model())")
        print("Firmware: \(try radio.firmwareVersion())")

    case "raw":
        guard args.count >= 2 else { fail(usage) }
        let radio = try connect(portPath)
        print(try radio.raw(args.dropFirst().joined(separator: " ")))

    case "dump":
        var range = Radio.channelRange
        if args.count >= 2 {
            let parts = args[1].split(separator: "-").compactMap { Int($0) }
            guard let first = parts.first, let last = parts.last, parts.count <= 2,
                  first <= last, Radio.channelRange.contains(first), Radio.channelRange.contains(last)
            else { fail("Bad channel range \"\(args[1])\" (expected e.g. 0-99)") }
            range = first...last
        }
        let radio = try connect(portPath)
        print([pad("Ch", 3), pad("Frequency", 11, right: true), pad("Offset", 14), pad("Mode", 4),
               pad("Tone", 12), pad("Step", 6, right: true), pad("URCALL", 8), "Flags"]
            .joined(separator: "  "))
        var used = 0
        for n in range {
            guard let ch = try radio.readChannel(n) else { continue }
            used += 1
            var flags: [String] = []
            if ch.reverse { flags.append("rev") }
            if ch.lockout { flags.append("lockout") }
            if ch.fineMode { flags.append("fine \(Tables.fineSteps[ch.fineStepCode])Hz") }
            let step = String(format: "%g", ch.stepHz / 1000)
            print([pad(String(format: "%03d", ch.number), 3), pad(mhz(ch.frequency), 11, right: true),
                   pad(offsetColumn(ch), 14), pad(ch.mode.label, 4), pad(toneColumn(ch), 12),
                   pad(step, 6, right: true), pad(ch.isDigital ? ch.urcall : "", 8),
                   flags.joined(separator: " ")]
                .joined(separator: "  "))
        }
        print("\(used) of \(range.count) channels in use.")

    case "clone":
        let flags = Set(args.dropFirst().filter { $0.hasPrefix("--") })
        guard let file = args.dropFirst().first(where: { !$0.hasPrefix("--") }) else { fail(usage) }
        let radio = try connect(portPath)

        var live: [Int: Channel] = [:]
        if flags.contains("--check") {
            for n in Radio.channelRange { live[n] = try radio.readChannel(n) }
            print("Read \(live.count) channels with live commands.")
        }

        let blocks = flags.contains("--full") ? 0..<MemoryImage.blockCount : MemoryImage.channelBlocks
        let started = Date()
        let image = try radio.readMemory(blocks: blocks) { done, total in
            if done % 16 == 0 || done == total {
                FileHandle.standardError.write(Data("\rReading block \(done)/\(total)".utf8))
            }
        }
        FileHandle.standardError.write(Data("\n".utf8))
        print("The radio restarts when it leaves programming mode; give it a few seconds before reconnecting.")
        try Data(image.bytes).write(to: URL(fileURLWithPath: file))
        print(String(format: "Saved %@ (%d blocks in %.1f s).", file, blocks.count, Date().timeIntervalSince(started)))
        let stored = try image.channels()
        printStored(stored)

        if flags.contains("--check") {
            var mismatches = 0
            let fromImage = Dictionary(uniqueKeysWithValues: stored.map { ($0.channel.number, $0.channel) })
            for n in Radio.channelRange where live[n] != fromImage[n] {
                mismatches += 1
                print("MISMATCH \(n):\n  live:  \(live[n]?.meCommand ?? "(empty)")\n  image: \(fromImage[n]?.meCommand ?? "(empty)")")
            }
            print(mismatches == 0 ? "Check passed: all 1000 slots decode identically from the image and from live commands."
                                  : "\(mismatches) slots differ.")
        }

    case "rename":
        guard args.count >= 3, let number = Int(args[1]), Radio.channelRange.contains(number) else { fail(usage) }
        let name = args.dropFirst(2).joined(separator: " ")
        guard name.count <= 16, name.allSatisfy({ $0.isASCII }) else { fail("Names are limited to 16 plain ASCII characters.") }
        let radio = try connect(portPath)
        let result = try radio.updateMemory(progress: showProgress) { image in
            guard var stored = try image.channel(number) else { fail("\nChannel \(number) is empty; nothing written.") }
            stored.name = name
            try image.setChannel(number, stored)
        }
        FileHandle.standardError.write(Data("\n".utf8))
        print("Wrote and verified \(result.written.count) block(s): \(result.written.map { String(format: "0x%03X", $0) }.joined(separator: ", ")).")
        print("The radio is restarting.")

    case "restore":
        guard args.count >= 2 else { fail(usage) }
        let backup = try MemoryImage(bytes: Array(try Data(contentsOf: URL(fileURLWithPath: args[1]))))
        let radio = try connect(portPath)
        let result = try radio.updateMemory(blocks: Radio.writableBlocks, progress: showProgress) { image in
            for block in Radio.writableBlocks { image.setBlock(block, backup.block(block)) }
        }
        FileHandle.standardError.write(Data("\n".utf8))
        print(result.written.isEmpty ? "The radio already matches the backup; nothing written."
                                     : "Wrote and verified \(result.written.count) block(s).")
        print("The radio is restarting.")

    case "show":
        guard args.count >= 2 else { fail(usage) }
        let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        printStored(try MemoryImage(bytes: Array(data)).channels())

    default:
        fail(usage)
    }
} catch {
    fail("error: \(error)")
}
