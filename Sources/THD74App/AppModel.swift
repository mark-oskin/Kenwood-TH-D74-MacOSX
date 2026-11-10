import AppKit
import Observation
import THD74Kit

/// One row of the channel table: a memory slot that may be empty.
struct ChannelRow: Identifiable, Equatable {
    let number: Int
    var stored: StoredChannel?
    var id: Int { number }
}

@MainActor
@Observable
final class AppModel {
    private(set) var image: MemoryImage?
    var rows: [ChannelRow] = []
    private(set) var originalRows: [ChannelRow] = []
    private(set) var sourceDescription = "No data loaded"

    /// Names of the radio's 30 memory groups.
    var groupNames = [String](repeating: "", count: MemoryImage.groupCount)
    private(set) var originalGroupNames = [String](repeating: "", count: MemoryImage.groupCount)
    /// When set, the table shows only this group.
    var groupFilter: Int?
    var editingGroups = false
    var importSession: ImportSession?

    var showEmptySlots = false
    var searchText = ""
    var selection = Set<Int>()

    // Radio activity
    private(set) var isBusy = false
    private(set) var busyMessage = ""
    private(set) var progress: Double = 0
    var errorMessage: String?
    var lastWriteSummary: String?
    var confirmingWrite = false

    var hasData: Bool { image != nil }
    var canSaveBackup: Bool { image?.isComplete == true }
    var usedCount: Int { rows.lazy.filter { $0.stored != nil }.count }
    var modifiedCount: Int { zip(rows, originalRows).lazy.filter { $0 != $1 }.count }
    var groupNamesModified: Bool { groupNames != originalGroupNames }
    var hasUnwrittenChanges: Bool { modifiedCount > 0 || groupNamesModified }

    func groupLabel(_ group: Int) -> String {
        let name = groupNames.indices.contains(group) ? groupNames[group] : ""
        return name.isEmpty ? "Group \(group)" : "\(group) · \(name)"
    }

    func channelCount(inGroup group: Int) -> Int {
        rows.lazy.filter { $0.stored?.group == group }.count
    }

    private func slotGroup(_ number: Int) -> Int {
        (try? image?.group(ofSlot: number)) ?? number / 100
    }

    func isModified(_ number: Int) -> Bool {
        rows.indices.contains(number) && rows[number] != originalRows[number]
    }

    var visibleRows: [ChannelRow] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { row in
            guard let stored = row.stored else {
                return showEmptySlots && query.isEmpty && (groupFilter == nil || slotGroup(row.number) == groupFilter)
            }
            if let groupFilter, stored.group != groupFilter { return false }
            guard !query.isEmpty else { return true }
            return stored.name.lowercased().contains(query)
                || Formatting.mhz(stored.channel.frequency).contains(query)
                || String(format: "%03d", row.number).contains(query)
        }
    }

    // MARK: Loading

    private func load(_ image: MemoryImage, source: String) throws {
        let rows = try Radio.channelRange.map { ChannelRow(number: $0, stored: try image.channel($0)) }
        self.image = image
        self.rows = rows
        self.originalRows = rows
        self.groupNames = try (0..<MemoryImage.groupCount).map { try image.groupName($0) }
        self.originalGroupNames = groupNames
        self.groupFilter = nil
        self.sourceDescription = source
        self.selection = []
    }

    func openBackup(at url: URL) {
        do {
            let data = try Data(contentsOf: url)
            try load(try MemoryImage(bytes: Array(data)), source: "File: \(url.lastPathComponent)")
        } catch {
            errorMessage = "Could not open \(url.lastPathComponent).\n\(error)"
        }
    }

    func chooseBackupToOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.message = "Choose a TH-D74 memory backup (.bin)"
        if panel.runModal() == .OK, let url = panel.url { openBackup(at: url) }
    }

    /// The memory image with the table's edits applied.
    private func editedImage() throws -> MemoryImage? {
        guard var image else { return nil }
        for (row, original) in zip(rows, originalRows) where row != original {
            try image.setChannel(row.number, row.stored)
        }
        for (group, name) in groupNames.enumerated() where name != originalGroupNames[group] {
            try image.setGroupName(group, name)
        }
        return image
    }

    func saveBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "th-d74-backup.bin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let edited = try editedImage() else { return }
            try Data(edited.bytes).write(to: url)
            image = edited
            originalRows = rows
            originalGroupNames = groupNames
            sourceDescription = "File: \(url.lastPathComponent)"
        } catch {
            errorMessage = "Could not save.\n\(error)"
        }
    }

    // MARK: Radio

    /// Reads from the radio. `full` reads the entire memory (needed for a
    /// complete backup file); otherwise only the channel area.
    ///
    /// Apple's Bluetooth framework only works on the main thread, so this
    /// runs there; the transport keeps the run loop turning while it waits,
    /// which lets the progress sheet update.
    func readFromRadio(full: Bool) {
        guard !isBusy else { return }
        isBusy = true
        progress = 0
        busyMessage = "Connecting to the radio…"
        // Scheduled as a run-loop block, not on the main dispatch queue: the
        // Bluetooth framework delivers incoming data through the main queue,
        // which cannot run while one of its own blocks is still executing.
        RunLoop.main.perform { MainActor.assumeIsolated { self.performRead(full: full) } }
    }

    private func performRead(full: Bool) {
        do {
            defer { isBusy = false }
            do {
                let radio: Radio
                if let usb = SerialPort.usbCandidatePorts().first {
                    radio = try Radio.connect(path: usb)
                } else {
                    radio = try Radio.connect(transport: try BluetoothTransport.openFirstPaired())
                }
                busyMessage = full ? "Reading the radio's full memory…" : "Reading channels…"
                let blocks = full ? 0..<MemoryImage.blockCount : MemoryImage.channelBlocks
                let image = try radio.readMemory(blocks: blocks) { done, total in
                    self.progress = Double(done) / Double(total)
                }
                let time = Date().formatted(date: .omitted, time: .shortened)
                try load(image, source: "Radio (\(full ? "full memory" : "channels"), read at \(time))")
            } catch {
                errorMessage = "Could not read from the radio.\n\(error)"
                NSLog("Radio read failed: %@", "\(error)")
            }
        }
    }

    /// Makes the radio's channels match the table. Runs one programming
    /// session that reads the radio's current channel memory, writes only
    /// the blocks that differ, and reads them back to verify.
    func writeToRadio() {
        guard !isBusy, hasData else { return }
        isBusy = true
        progress = 0
        busyMessage = "Connecting to the radio…"
        RunLoop.main.perform { MainActor.assumeIsolated { self.performWrite() } }
    }

    private func performWrite() {
        defer { isBusy = false }
        do {
            let radio: Radio
            if let usb = SerialPort.usbCandidatePorts().first {
                radio = try Radio.connect(path: usb)
            } else {
                radio = try Radio.connect(transport: try BluetoothTransport.openFirstPaired())
            }
            let rows = self.rows
            let groupNames = self.groupNames
            let originalGroupNames = self.originalGroupNames
            let result = try radio.updateMemory(progress: { step in
                switch step {
                case .reading(let done, let total):
                    self.busyMessage = "Checking what is on the radio…"
                    self.progress = Double(done) / Double(total)
                case .writing(let done, let total):
                    self.busyMessage = "Writing changes…"
                    self.progress = Double(done) / Double(total)
                case .verifying(let done, let total):
                    self.busyMessage = "Verifying…"
                    self.progress = Double(done) / Double(total)
                }
            }) { image in
                for row in rows { try image.setChannel(row.number, row.stored) }
                for (group, name) in groupNames.enumerated() where name != originalGroupNames[group] {
                    try image.setGroupName(group, name)
                }
            }

            // Keep a full backup image if we have one, with the edits applied.
            if image?.isComplete == true, let edited = try editedImage() {
                image = edited
            } else {
                image = result.image
            }
            originalRows = rows
            self.originalGroupNames = groupNames
            let time = Date().formatted(date: .omitted, time: .shortened)
            sourceDescription = "Radio (written at \(time))"
            lastWriteSummary = result.written.isEmpty
                ? "The radio already matched the table, so nothing was written."
                : "Wrote and verified \(result.written.count) memory block\(result.written.count == 1 ? "" : "s"). The radio is restarting."
        } catch {
            errorMessage = "Writing to the radio failed.\n\(error)\n\nThe radio was told to leave programming mode. Read from the radio again to see what it now holds."
            NSLog("Radio write failed: %@", "\(error)")
        }
    }

    // MARK: Editing

    /// Defaults for a channel created by typing a frequency into an empty slot.
    func makeChannel(number: Int, frequency: Int) -> StoredChannel {
        let uhf = frequency >= 300_000_000
        var channel = Channel(number: number, frequency: frequency)
        channel.offset = uhf ? 5_000_000 : 600_000
        channel.stepCode = Tables.stepCode(forFrequency: frequency)
        channel.txStepCode = channel.stepCode
        return StoredChannel(channel: channel, group: groupFilter ?? slotGroup(number))
    }

    func update(_ number: Int, _ change: (inout StoredChannel) -> Void) {
        guard rows.indices.contains(number), var stored = rows[number].stored else { return }
        change(&stored)
        rows[number].stored = stored
    }

    /// Sets a slot's frequency from user text in MHz. Empty text clears the
    /// slot. Returns false if the text is not a usable frequency.
    @discardableResult
    func setFrequency(_ number: Int, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            rows[number].stored = nil
            return true
        }
        guard let hz = Formatting.hertz(fromMHz: trimmed), Formatting.tunableRange.contains(hz) else { return false }
        if rows[number].stored == nil {
            rows[number].stored = makeChannel(number: number, frequency: hz)
        } else if let old = rows[number].stored?.channel {
            rows[number].stored?.channel.frequency = hz
            // Moving to another band, or off the current tuning grid, needs a new step.
            let changedBand = (old.frequency >= 300_000_000) != (hz >= 300_000_000)
            if changedBand || hz % Int(old.stepHz) != 0 {
                let step = Tables.stepCode(forFrequency: hz)
                rows[number].stored?.channel.stepCode = step
                rows[number].stored?.channel.txStepCode = step
            }
        }
        return true
    }

    func addChannel() {
        guard let slot = rows.first(where: { $0.stored == nil })?.number else { return }
        rows[slot].stored = makeChannel(number: slot, frequency: 146_520_000)
        selection = [slot]
    }

    func deleteSelected() {
        for number in selection where rows.indices.contains(number) { rows[number].stored = nil }
    }

    func revertAll() {
        rows = originalRows
        groupNames = originalGroupNames
    }

    // MARK: Importing

    func chooseCSVToImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Choose a CHIRP-format CSV file of repeaters"
        if panel.runModal() == .OK, let url = panel.url { beginImport(from: url) }
    }

    func beginImport(from url: URL) {
        guard hasData else {
            errorMessage = "Read from the radio or open a backup first, so the imported repeaters have somewhere to go."
            return
        }
        do {
            let text = try String(decoding: Data(contentsOf: url), as: UTF8.self)
            let result = try ChirpCSV.parse(text)
            let session = ImportSession(fileName: url.lastPathComponent, channels: result.channels, skipped: result.skipped.map { "Line \($0.line): \($0.reason)" })
            session.group = groupFilter ?? 0
            session.startChannel = firstEmptySlot(from: session.group * 100) ?? 0
            importSession = session
        } catch {
            errorMessage = "Could not import \(url.lastPathComponent).\n\(error)"
        }
    }

    func firstEmptySlot(from start: Int) -> Int? {
        rows[min(max(start, 0), rows.count)...].first { $0.stored == nil }?.number
            ?? rows.first { $0.stored == nil }?.number
    }

    /// The channel number already holding the same repeater, if any:
    /// same frequency, shift, offset and access tone.
    func existingSlot(matching candidate: StoredChannel) -> Int? {
        let c = candidate.channel
        return rows.first { row in
            guard let e = row.stored?.channel else { return false }
            guard e.frequency == c.frequency, e.txFrequency == c.txFrequency, e.toneMode == c.toneMode else { return false }
            switch c.toneMode {
            case .tone: return e.toneCode == c.toneCode
            case .ctcss: return e.ctcssCode == c.ctcssCode
            case .dcs: return e.dcsCode == c.dcsCode
            default: return true
            }
        }?.number
    }

    /// Puts the selected import rows into empty slots, in file order,
    /// starting at the session's start channel, in the session's group.
    func importSelected(_ session: ImportSession) {
        var slot = session.startChannel
        var added: [Int] = []
        var noRoom = 0
        for imported in session.channels where session.selection.contains(imported.id) {
            while slot < rows.count, rows[slot].stored != nil { slot += 1 }
            guard slot < rows.count else { noRoom += 1; continue }
            var stored = imported.stored
            stored.channel.number = slot
            stored.group = session.group
            rows[slot].stored = stored
            session.placed[imported.id] = slot
            session.selection.remove(imported.id)
            added.append(slot)
        }
        if let first = added.first, let last = added.last {
            session.message = "Added \(added.count) channel\(added.count == 1 ? "" : "s") to \(groupLabel(session.group)), in slots \(String(format: "%03d", first))–\(String(format: "%03d", last))."
                + (noRoom > 0 ? " \(noRoom) did not fit: no empty slots after \(String(format: "%03d", session.startChannel))." : "")
            session.startChannel = firstEmptySlot(from: last) ?? last
        } else if noRoom > 0 {
            session.message = "No empty slots at or after channel \(String(format: "%03d", session.startChannel))."
        }
    }
}

/// The state of one import sheet: the file's rows and what has been done with them.
@MainActor
@Observable
final class ImportSession: Identifiable {
    let fileName: String
    let channels: [ImportedChannel]
    let skipped: [String]
    var selection = Set<Int>()
    /// Import row id → the channel slot it was placed in.
    var placed: [Int: Int] = [:]
    var group = 0
    var startChannel = 0
    var maxMiles = 25.0
    var searchText = ""
    var message: String?

    var hasDistances: Bool { channels.contains { $0.distanceMiles != nil } }

    init(fileName: String, channels: [ImportedChannel], skipped: [String]) {
        self.fileName = fileName
        self.channels = channels
        self.skipped = skipped
    }

    var visibleChannels: [ImportedChannel] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return channels }
        return channels.filter {
            $0.stored.name.lowercased().contains(query) || $0.comment.lowercased().contains(query)
                || Formatting.mhz($0.stored.channel.frequency).contains(query)
        }
    }
}

enum Formatting {
    /// The TH-D74 receives 0.1–524 MHz.
    static let tunableRange = 100_000...524_000_000

    static func mhz(_ hz: Int) -> String {
        var text = String(format: "%.6f", Double(hz) / 1_000_000)
        // Keep at least kHz precision: 144.390, 0.600, 145.2125.
        while text.hasSuffix("0"), let dot = text.firstIndex(of: "."), text.distance(from: dot, to: text.endIndex) > 4 {
            text.removeLast()
        }
        return text
    }

    static func hertz(fromMHz text: String) -> Int? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value > 0 else { return nil }
        return Int((value * 1_000_000).rounded())
    }

    static func tone(_ hz: Double) -> String { String(format: "%.1f", hz) }
    static func dcs(_ code: Int) -> String { String(format: "%03d", code) }
    static func step(_ hz: Double) -> String {
        let khz = hz / 1000
        return String(khz)
    }
}
