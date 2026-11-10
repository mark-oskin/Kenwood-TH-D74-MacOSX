import SwiftUI
import THD74Kit

@main
struct THD74App: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("TH-D74 Programmer", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 960, minHeight: 420)
                .onAppear { LaunchOptions.apply(to: model) }
        }
        .defaultSize(width: 1240, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Backup…") { model.chooseBackupToOpen() }
                    .keyboardShortcut("o")
                Button("Save Backup As…") { model.saveBackup() }
                    .keyboardShortcut("s")
                    .disabled(!model.canSaveBackup)
                Divider()
                Button("Import Repeaters from CSV…") { model.chooseCSVToImport() }
                    .keyboardShortcut("i")
                    .disabled(!model.hasData)
            }
            CommandMenu("Radio") {
                Button("Read Channels from Radio") { model.readFromRadio(full: false) }
                    .keyboardShortcut("r")
                Button("Read Full Memory from Radio") { model.readFromRadio(full: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Write to Radio…") { model.confirmingWrite = true }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(!model.hasData)
            }
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.hasData {
                ChannelTable(model: model)
            } else {
                ContentUnavailableView {
                    Label("No channels loaded", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("Read the channels from a paired or plugged-in TH-D74, or open a saved backup.")
                } actions: {
                    Button("Read from Radio") { model.readFromRadio(full: false) }
                        .buttonStyle(.borderedProminent)
                    Button("Open Backup…") { model.chooseBackupToOpen() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            statusBar
        }
        .searchable(text: $model.searchText, prompt: "Name, frequency or channel")
        .toolbar {
            ToolbarItemGroup {
                Button { model.readFromRadio(full: false) } label: {
                    Label("Read from Radio", systemImage: "arrow.down.circle")
                }
                .help("Read the channels from the radio")

                Button { model.confirmingWrite = true } label: {
                    Label("Write to Radio", systemImage: "arrow.up.circle")
                }
                .help("Write the channels in this table to the radio")
                .disabled(!model.hasData)

                Button { model.chooseCSVToImport() } label: {
                    Label("Import CSV", systemImage: "square.and.arrow.down")
                }
                .help("Import repeaters from a CHIRP-format CSV file")
                .disabled(!model.hasData)

                Picker("Group", selection: $model.groupFilter) {
                    Text("All Groups").tag(Int?.none)
                    Divider()
                    ForEach(0..<MemoryImage.groupCount, id: \.self) { group in
                        let count = model.channelCount(inGroup: group)
                        Text(model.groupLabel(group) + (count > 0 ? "  (\(count))" : "")).tag(Int?.some(group))
                    }
                }
                .help("Show only one memory group")
                .disabled(!model.hasData)

                Button { model.editingGroups = true } label: {
                    Label("Group Names", systemImage: "folder")
                }
                .help("Rename the radio's memory groups")
                .disabled(!model.hasData)

                Button { model.addChannel() } label: {
                    Label("Add Channel", systemImage: "plus")
                }
                .help("Add a channel in the first empty slot")
                .disabled(!model.hasData)

                Toggle(isOn: $model.showEmptySlots) {
                    Label("Show Empty Slots", systemImage: "list.number")
                }
                .help("Show all 1000 memory slots, including empty ones")
                .disabled(!model.hasData)

                Button { model.revertAll() } label: {
                    Label("Revert Changes", systemImage: "arrow.uturn.backward")
                }
                .help("Discard all changes made since loading")
                .disabled(!model.hasUnwrittenChanges)
            }
        }
        .sheet(isPresented: .constant(model.isBusy)) {
            VStack(spacing: 14) {
                Text(model.busyMessage).font(.headline)
                ProgressView(value: model.progress)
                    .frame(width: 280)
                Text("The radio shows its programming screen and restarts when this finishes. Keep it on and in range.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 280)
            }
            .padding(24)
            .interactiveDismissDisabled()
        }
        .sheet(item: $model.importSession) { session in
            ImportSheet(model: model, session: session)
        }
        .sheet(isPresented: $model.editingGroups) {
            GroupsSheet(model: model)
        }
        .confirmationDialog("Write these channels to the radio?", isPresented: $model.confirmingWrite) {
            Button("Write to Radio") { model.writeToRadio() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The radio will be made to match this table: \(model.usedCount) channel\(model.usedCount == 1 ? "" : "s")"
                 + (model.modifiedCount > 0 ? ", \(model.modifiedCount) changed since loading" : "")
                 + ". Slots that are empty here will be cleared on the radio. The radio restarts afterwards.")
        }
        .alert("Written to the radio", isPresented: Binding(
            get: { model.lastWriteSummary != nil },
            set: { if !$0 { model.lastWriteSummary = nil } }
        )) {
            Button("OK") { model.lastWriteSummary = nil }
        } message: {
            Text(model.lastWriteSummary ?? "")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text(model.sourceDescription)
            if model.hasData {
                Text("\(model.usedCount) of 1000 channels in use")
                if model.hasUnwrittenChanges {
                    Text((model.modifiedCount > 0 ? "\(model.modifiedCount) changed" : "Group names changed") + ", not yet written to the radio")
                        .foregroundStyle(Color.accentColor)
                }
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Command-line options used for development:
///   --open <file>       load a backup at launch
///   --read-radio        start a channel read at launch
///   --import <csv>      open the import sheet for a CSV file
///   --import-within <miles> --import-group <n>
///                       with --import: add everything within that distance to that group
///   --snapshot <png>    save a picture of the window, then quit
@MainActor
enum LaunchOptions {
    private static var applied = false

    static func apply(to model: AppModel) {
        guard !applied else { return }
        applied = true
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let path = value(after: "--open") { model.openBackup(at: URL(fileURLWithPath: path)) }
        if args.contains("--show-empty") { model.showEmptySlots = true }
        if args.contains("--edit-groups") { model.editingGroups = true }
        if let path = value(after: "--import") {
            model.beginImport(from: URL(fileURLWithPath: path))
            if let session = model.importSession, let miles = value(after: "--import-within").flatMap(Double.init) {
                session.group = value(after: "--import-group").flatMap(Int.init) ?? 0
                session.startChannel = model.firstEmptySlot(from: session.group * 100) ?? 0
                session.maxMiles = miles
                session.selection = Set(session.channels.filter {
                    ($0.distanceMiles ?? .infinity) <= miles && model.existingSlot(matching: $0.stored) == nil
                }.map(\.id))
                model.importSelected(session)
            }
        }
        if args.contains("--read-radio") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.readFromRadio(full: false) }
        }
        if let path = value(after: "--snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + (args.contains("--read-radio") ? 25 : 2)) {
                @MainActor func capture(_ window: NSWindow, to path: String) {
                    guard let view = window.contentView?.superview ?? window.contentView,
                          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }) {
                    capture(window, to: path)
                    if let sheet = window.attachedSheet {
                        capture(sheet, to: path.replacingOccurrences(of: ".png", with: "-sheet.png"))
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }
}
