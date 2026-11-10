import SwiftUI
import THD74Kit

/// A text field that edits a draft and only commits on Return or when it
/// loses focus, so half-typed values never reach the model.
struct CommitField: View {
    let value: String
    var placeholder = ""
    var alignment: TextAlignment = .leading
    /// Returns false to reject the text, which reverts the field.
    let commit: (String) -> Bool

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .multilineTextAlignment(alignment)
            .focused($focused)
            .onAppear { draft = value }
            .onChange(of: value) { _, new in if !focused { draft = new } }
            .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
            .onSubmit { apply() }
    }

    private func apply() {
        guard draft != value else { return }
        if !commit(draft) {
            NSSound.beep()
            draft = value
        }
    }
}

/// A compact menu picker for a table cell.
struct CellPicker<Value: Hashable>: View {
    let selection: Binding<Value>
    let options: [(value: Value, label: String)]

    var body: some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .buttonStyle(.borderless)
        .fixedSize()
    }
}

struct ChannelTable: View {
    @Bindable var model: AppModel

    private static let shiftOptions: [(value: Shift, label: String)] =
        [(.simplex, "Simplex"), (.up, "+"), (.down, "−"), (.split, "Split")]
    private static let toneModeOptions: [(value: ToneMode, label: String)] =
        [(.none, "None"), (.tone, "Tone"), (.ctcss, "CTCSS"), (.dcs, "DCS"), (.cross, "Cross")]
    private static let modeOptions = Mode.allCases.map { (value: $0, label: $0.label) }
    private static let toneOptions = Tables.tones.indices.map { (value: $0, label: Formatting.tone(Tables.tones[$0])) }
    private static let dcsOptions = Tables.dcsCodes.indices.map { (value: $0, label: Formatting.dcs(Tables.dcsCodes[$0])) }
    private static let crossOptions = CrossMode.allCases.map { (value: $0, label: $0.label) }
    private static let stepOptions = Tables.steps.indices.map { (value: $0, label: Formatting.step(Tables.steps[$0])) }

    /// A binding to one field of a stored channel in the model.
    private func field<T>(_ number: Int, _ keyPath: WritableKeyPath<StoredChannel, T>, default fallback: T) -> Binding<T> {
        Binding(
            get: { model.rows[number].stored?[keyPath: keyPath] ?? fallback },
            set: { value in model.update(number) { $0[keyPath: keyPath] = value } }
        )
    }

    // Each cell is its own small function, and the columns are split into
    // two builders, to keep the Swift type checker's work manageable.

    @ViewBuilder private func numberCell(_ row: ChannelRow) -> some View {
        HStack(spacing: 4) {
            Text(String(format: "%03d", row.number)).monospacedDigit()
            Circle()
                .fill(model.isModified(row.number) ? Color.accentColor : .clear)
                .frame(width: 6, height: 6)
                .help(model.isModified(row.number) ? "Changed since it was loaded" : "")
        }
        .foregroundStyle(row.stored == nil ? .secondary : .primary)
    }

    @ViewBuilder private func nameCell(_ row: ChannelRow) -> some View {
        if let stored = row.stored {
            CommitField(value: stored.name) { text in
                guard text.count <= 16, text.allSatisfy({ $0.isASCII }) else { return false }
                model.update(row.number) { $0.name = text }
                return true
            }
        }
    }

    @ViewBuilder private func frequencyCell(_ row: ChannelRow) -> some View {
        CommitField(
            value: row.stored.map { Formatting.mhz($0.channel.frequency) } ?? "",
            placeholder: row.stored == nil ? "empty" : "",
            alignment: .trailing
        ) { model.setFrequency(row.number, text: $0) }
        .monospacedDigit()
    }

    private func shiftBinding(_ number: Int) -> Binding<Shift> {
        Binding(
            get: {
                guard let channel = model.rows[number].stored?.channel else { return .simplex }
                return channel.isSplit ? .split : channel.shift
            },
            set: { shift in
                model.update(number) {
                    $0.channel.shift = shift
                    $0.channel.oddSplit = shift == .split
                }
            }
        )
    }

    @ViewBuilder private func shiftCell(_ row: ChannelRow) -> some View {
        if row.stored != nil {
            CellPicker(selection: shiftBinding(row.number), options: Self.shiftOptions)
        }
    }

    @ViewBuilder private func offsetCell(_ row: ChannelRow) -> some View {
        if let channel = row.stored?.channel, channel.shift != .simplex || channel.isSplit {
            CommitField(value: Formatting.mhz(channel.offset), alignment: .trailing) { text in
                guard let hz = Formatting.hertz(fromMHz: text), hz <= Formatting.tunableRange.upperBound else { return false }
                model.update(row.number) { $0.channel.offset = hz }
                return true
            }
            .monospacedDigit()
        }
    }

    @ViewBuilder private func groupCell(_ row: ChannelRow) -> some View {
        if row.stored != nil {
            CellPicker(
                selection: field(row.number, \.group, default: 0),
                options: (0..<MemoryImage.groupCount).map { (value: $0, label: model.groupLabel($0)) })
        }
    }

    @ViewBuilder private func modeCell(_ row: ChannelRow) -> some View {
        if row.stored != nil {
            CellPicker(selection: field(row.number, \.channel.mode, default: .fm), options: Self.modeOptions)
        }
    }

    @ViewBuilder private func squelchCell(_ row: ChannelRow) -> some View {
        if row.stored != nil {
            CellPicker(selection: field(row.number, \.channel.toneMode, default: .none), options: Self.toneModeOptions)
        }
    }

    @ViewBuilder private func toneCell(_ row: ChannelRow) -> some View {
        if let channel = row.stored?.channel {
            switch channel.toneMode {
            case .none: EmptyView()
            case .tone: CellPicker(selection: field(row.number, \.channel.toneCode, default: 8), options: Self.toneOptions)
            case .ctcss: CellPicker(selection: field(row.number, \.channel.ctcssCode, default: 8), options: Self.toneOptions)
            case .dcs: CellPicker(selection: field(row.number, \.channel.dcsCode, default: 0), options: Self.dcsOptions)
            case .cross: CellPicker(selection: field(row.number, \.channel.crossMode, default: .dcsOff), options: Self.crossOptions)
            }
        }
    }

    @ViewBuilder private func stepCell(_ row: ChannelRow) -> some View {
        if row.stored != nil {
            CellPicker(selection: field(row.number, \.channel.stepCode, default: 0), options: Self.stepOptions)
        }
    }

    @ViewBuilder private func skipCell(_ row: ChannelRow) -> some View {
        if row.stored != nil {
            Toggle("", isOn: field(row.number, \.channel.lockout, default: false))
                .labelsHidden()
                .help("Lock this channel out of scans")
        }
    }

    @TableColumnBuilder<ChannelRow, Never>
    private var identityColumns: some TableColumnContent<ChannelRow, Never> {
        TableColumn("Ch") { (row: ChannelRow) in numberCell(row) }
            .width(52)
        TableColumn("Name") { (row: ChannelRow) in nameCell(row) }
            .width(min: 110, ideal: 140)
        TableColumn("Group") { (row: ChannelRow) in groupCell(row) }
            .width(min: 90, ideal: 120)
        TableColumn("Frequency (MHz)") { (row: ChannelRow) in frequencyCell(row) }
            .width(min: 100, ideal: 110)
        TableColumn("Shift") { (row: ChannelRow) in shiftCell(row) }
            .width(84)
        TableColumn("Offset / TX (MHz)") { (row: ChannelRow) in offsetCell(row) }
            .width(min: 90, ideal: 100)
    }

    @TableColumnBuilder<ChannelRow, Never>
    private var signalColumns: some TableColumnContent<ChannelRow, Never> {
        TableColumn("Mode") { (row: ChannelRow) in modeCell(row) }
            .width(76)
        TableColumn("Squelch") { (row: ChannelRow) in squelchCell(row) }
            .width(84)
        TableColumn("Tone / Code") { (row: ChannelRow) in toneCell(row) }
            .width(110)
        TableColumn("Step (kHz)") { (row: ChannelRow) in stepCell(row) }
            .width(78)
        TableColumn("Skip") { (row: ChannelRow) in skipCell(row) }
            .width(40)
    }

    var body: some View {
        Table(model.visibleRows, selection: $model.selection) {
            identityColumns
            signalColumns
        }
        .contextMenu(forSelectionType: Int.self) { numbers in
            if !numbers.isEmpty {
                Button("Clear \(numbers.count == 1 ? "Channel" : "\(numbers.count) Channels")", role: .destructive) {
                    model.selection = numbers
                    model.deleteSelected()
                }
            }
        }
        .onDeleteCommand { model.deleteSelected() }
    }
}
