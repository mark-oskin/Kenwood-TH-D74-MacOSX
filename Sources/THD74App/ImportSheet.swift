import SwiftUI
import THD74Kit

/// Lists the repeaters in an import file and lets the user add chosen ones
/// to a group. It stays open after adding so that, for example, nearby
/// repeaters can go into one group and the rest into another.
struct ImportSheet: View {
    @Bindable var model: AppModel
    @Bindable var session: ImportSession

    private func describeShift(_ ch: Channel) -> String {
        if ch.isSplit { return "TX " + Formatting.mhz(ch.offset) }
        switch ch.shift {
        case .up: return "+" + Formatting.mhz(ch.offset)
        case .down: return "−" + Formatting.mhz(ch.offset)
        default: return "Simplex"
        }
    }

    private func describeTone(_ ch: Channel) -> String {
        switch ch.toneMode {
        case .none: ""
        case .tone: "Tone " + Formatting.tone(ch.toneHz)
        case .ctcss: "CTCSS " + Formatting.tone(ch.ctcssHz)
        case .dcs: "DCS " + Formatting.dcs(ch.dcsNumber)
        case .cross: ch.crossMode.label
        }
    }

    private func status(_ imported: ImportedChannel) -> String {
        if let slot = session.placed[imported.id] { return String(format: "Added as %03d", slot) }
        if let slot = model.existingSlot(matching: imported.stored) { return String(format: "Already in %03d", slot) }
        return ""
    }

    private var selectable: [ImportedChannel] {
        session.visibleChannels.filter { session.placed[$0.id] == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import Repeaters").font(.title3.bold())
                    Text("\(session.channels.count) repeaters in \(session.fileName)"
                         + (session.skipped.isEmpty ? "" : " · \(session.skipped.count) rows could not be used"))
                        .foregroundStyle(.secondary)
                        .help(session.skipped.prefix(12).joined(separator: "\n"))
                }
                Spacer()
                TextField("Filter", text: $session.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }

            HStack(spacing: 8) {
                if session.hasDistances {
                    Button("Select Within") {
                        session.selection = Set(selectable.filter {
                            ($0.distanceMiles ?? .infinity) <= session.maxMiles && model.existingSlot(matching: $0.stored) == nil
                        }.map(\.id))
                    }
                    TextField("", value: $session.maxMiles, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Text("miles")
                    Divider().frame(height: 16)
                }
                Button("Select All New") {
                    session.selection = Set(selectable.filter { model.existingSlot(matching: $0.stored) == nil }.map(\.id))
                }
                Button("Select None") { session.selection = [] }
                Spacer()
                Text("\(session.selection.count) selected").foregroundStyle(.secondary)
            }

            Table(session.visibleChannels) {
                TableColumn("") { imported in
                    Toggle("", isOn: Binding(
                        get: { session.selection.contains(imported.id) },
                        set: { on in
                            if on { session.selection.insert(imported.id) } else { session.selection.remove(imported.id) }
                        }
                    ))
                    .labelsHidden()
                    .disabled(session.placed[imported.id] != nil)
                }
                .width(24)
                TableColumn("Name") { Text($0.stored.name) }
                    .width(min: 110, ideal: 140)
                TableColumn("Frequency") { Text(Formatting.mhz($0.stored.channel.frequency)).monospacedDigit() }
                    .width(80)
                TableColumn("Shift") { Text(describeShift($0.stored.channel)).monospacedDigit() }
                    .width(84)
                TableColumn("Access") { Text(describeTone($0.stored.channel)).monospacedDigit() }
                    .width(84)
                TableColumn("Mode") { Text($0.stored.channel.mode.label) }
                    .width(44)
                TableColumn("Miles") { imported in
                    Text(imported.distanceMiles.map { String(format: "%.1f", $0) } ?? "")
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(48)
                TableColumn("Status") { Text(status($0)).foregroundStyle(.secondary) }
                    .width(96)
                TableColumn("Details") { imported in
                    Text(imported.comment).foregroundStyle(.secondary).help(imported.comment)
                }
            }
            .frame(minHeight: 320)

            if let message = session.message {
                Text(message).foregroundStyle(Color.accentColor)
            }

            HStack(spacing: 8) {
                Text("Add to")
                Picker("", selection: $session.group) {
                    ForEach(0..<MemoryImage.groupCount, id: \.self) { Text(model.groupLabel($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 170)
                .onChange(of: session.group) { _, group in
                    session.startChannel = model.firstEmptySlot(from: group * 100) ?? 0
                }
                Text("starting at channel")
                TextField("", value: $session.startChannel, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                    .help("Selected repeaters fill empty slots from this channel upwards")
                Spacer()
                Button("Done") { model.importSession = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Add \(session.selection.count) Channel\(session.selection.count == 1 ? "" : "s")") {
                    session.startChannel = min(max(session.startChannel, 0), 999)
                    model.importSelected(session)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.selection.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 940, idealWidth: 1000, minHeight: 520)
    }
}

/// Edits the names of the radio's 30 memory groups.
struct GroupsSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Memory Groups").font(.title3.bold())
            Text("Names can be up to 16 characters. Channel counts are for the table as it is now.")
                .foregroundStyle(.secondary)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    ForEach(0..<MemoryImage.groupCount, id: \.self) { group in
                        GridRow {
                            Text("\(group)").monospacedDigit().foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            TextField("Group \(group)", text: Binding(
                                get: { model.groupNames[group] },
                                set: { model.groupNames[group] = String($0.filter(\.isASCII).prefix(16)) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            let count = model.channelCount(inGroup: group)
                            Text(count == 0 ? "" : "\(count) channel\(count == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.trailing, 8)
            }
            .frame(height: 360)
            HStack {
                Spacer()
                Button("Done") { model.editingGroups = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}
