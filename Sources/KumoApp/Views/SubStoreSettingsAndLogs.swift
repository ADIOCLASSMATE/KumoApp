import SwiftUI
import KumoCoreKit

// MARK: - Parser section

struct SubStoreParserSection: View {
    @Environment(SubStoreStore.self) private var subStore
    @State private var mode: ParserMode = .proxies
    @State private var platform = "JSON"
    @State private var input = ""
    @State private var result = ""
    @State private var isParsing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker(String(localized: "Parser type"), selection: $mode) {
                    ForEach(ParserMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)

                TextField("Target", text: $platform)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)

                Spacer()

                Button {
                    Task { await parse() }
                } label: {
                    if isParsing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(String(localized: "Parse"), systemImage: "arrow.right.doc.on.clipboard")
                    }
                }
                .disabled(isParsing || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Input"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $input)
                        .font(.body.monospaced())
                }
                .padding(12)
                .frame(minWidth: 320)

                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Result"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(result)
                            .font(.body.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
                .padding(12)
                .frame(minWidth: 320)
            }
        }
    }

    private func parse() async {
        isParsing = true
        defer { isParsing = false }

        let trimmedPlatform = platform.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = trimmedPlatform.isEmpty ? "JSON" : trimmedPlatform
        let parsed: String?
        switch mode {
        case .proxies:
            parsed = await subStore.parseProxies(data: input, platform: target)
        case .rules:
            parsed = await subStore.parseRules(data: input, platform: target)
        }
        result = parsed ?? ""
    }
}

private enum ParserMode: String, CaseIterable, Identifiable {
    case proxies
    case rules

    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .proxies: "Proxies"
        case .rules: "Rules"
        }
    }
}

// MARK: - Settings section

struct SubStoreSettingsSection: View {
    @Environment(SubStoreStore.self) private var subStore
    @State private var raw: String = "{}"
    @State private var parseError: String?
    @State private var lastLoadedVersion: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(String(localized: "Sub-Store backend settings"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button(String(localized: "Backup to Gist (upload)")) {
                        Task { await subStore.performGistBackup(action: "upload") }
                    }
                    Button(String(localized: "Restore from Gist (download)")) {
                        Task { await subStore.performGistBackup(action: "download") }
                    }
                } label: {
                    Label(String(localized: "Gist"), systemImage: "icloud")
                }
                .menuStyle(.button)
                Button {
                    Task {
                        await subStore.refreshSettings()
                        load()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Reload settings from backend"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                TextEditor(text: $raw)
                    .font(.body.monospaced())
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                if let parseError {
                    Label(parseError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .padding(8)
                }
                Divider()
                HStack {
                    Spacer()
                    Button(String(localized: "Reset")) { load() }
                    Button(String(localized: "Apply")) { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(parseError != nil)
                }
                .padding(8)
            }
        }
        .task {
            if subStore.settings.raw.isEmpty {
                await subStore.refreshSettings()
            }
            load()
        }
        .onChange(of: subStore.settings.raw) {
            load()
        }
    }

    private func load() {
        guard let data = try? JSONEncoder.subStorePretty.encode(subStore.settings.raw),
              let text = String(data: data, encoding: .utf8) else {
            raw = "{}"
            parseError = nil
            return
        }
        raw = text
        parseError = nil
    }

    private func apply() {
        guard let data = raw.data(using: .utf8) else {
            parseError = "Invalid encoding"
            return
        }
        do {
            let dict = try JSONDecoder().decode([String: JSONValue].self, from: data)
            parseError = nil
            Task { await subStore.saveSettings(SubStoreSettings(raw: dict)) }
        } catch {
            parseError = "JSON: \(error.localizedDescription)"
        }
    }
}

// MARK: - Logs section

struct SubStoreLogsSection: View {
    @Environment(SubStoreStore.self) private var subStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(format: String(localized: "%@ log entries"), String(subStore.logs.count)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await subStore.refreshLogs() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Refresh logs"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if subStore.logs.isEmpty {
                ContentUnavailableView(
                    "No log entries yet",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(String(localized: "Sub-Store records actions like syncs and parser errors. Refresh to load the latest."))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(subStore.logs) { (entry: SubStoreLogEntry) in
                            LogRowView(entry: entry)
                            Divider()
                        }
                    }
                }
            }
        }
    }

}

private struct LogRowView: View {
    let entry: SubStoreLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let level = entry.level {
                Text(level.uppercased())
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(levelTint(level).opacity(0.18), in: .capsule)
                    .foregroundStyle(levelTint(level))
            }
            if let time = entry.time {
                Text(Date(timeIntervalSince1970: TimeInterval(time)).formatted(.dateTime.hour().minute().second()))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
            }
            Text(entry.message)
                .font(.body.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func levelTint(_ level: String) -> Color {
        switch level.lowercased() {
        case "error", "fatal": .red
        case "warn", "warning": .orange
        case "info": .accentColor
        case "debug": .secondary
        default: .secondary
        }
    }
}
