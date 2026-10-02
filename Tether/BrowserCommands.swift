import SwiftUI
import TetherCore

/// What the focused browser can do right now; `nil` members disable their menu items.
struct BrowserActions {
    var newFolder: (() -> Void)?
    var refresh: () -> Void
    var goBack: (() -> Void)?
    var goForward: (() -> Void)?
    var goUp: (() -> Void)?
    var open: (() -> Void)?
    var download: (() -> Void)?
    var rename: (() -> Void)?
    var delete: (() -> Void)?
    var eject: (() -> Void)?
    var find: (() -> Void)?
    var showIcons: (() -> Void)?
    var showList: (() -> Void)?
    var quickLook: (() -> Void)?
}

extension FocusedValues {
    @Entry var browserActions: BrowserActions?
}

struct BrowserCommands: Commands {
    @FocusedValue(\.browserActions) private var actions
    @AppStorage(SettingsKey.showHiddenFiles) private var showHiddenFiles = false

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Folder") { actions?.newFolder?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions?.newFolder == nil)
            Divider()
            Button("Open") { actions?.open?() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(actions?.open == nil)
            Button("Quick Look") { actions?.quickLook?() }
                .keyboardShortcut("y")
                .disabled(actions?.quickLook == nil)
            Button("Download") { actions?.download?() }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(actions?.download == nil)
            Button("Rename") { actions?.rename?() }
                .disabled(actions?.rename == nil)
            Button("Delete…") { actions?.delete?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(actions?.delete == nil)
            Divider()
            Button("Eject") { actions?.eject?() }
                .keyboardShortcut("e")
                .disabled(actions?.eject == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find") { actions?.find?() }
                .keyboardShortcut("f")
                .disabled(actions?.find == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("as Icons") { actions?.showIcons?() }
                .keyboardShortcut("1")
                .disabled(actions?.showIcons == nil)
            Button("as List") { actions?.showList?() }
                .keyboardShortcut("2")
                .disabled(actions?.showList == nil)
            Divider()
            Button("Refresh") { actions?.refresh() }
                .keyboardShortcut("r")
                .disabled(actions == nil)
            Toggle("Show Hidden Files", isOn: $showHiddenFiles)
                .keyboardShortcut(".", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            Button("Back") { actions?.goBack?() }
                .keyboardShortcut("[")
                .disabled(actions?.goBack == nil)
            Button("Forward") { actions?.goForward?() }
                .keyboardShortcut("]")
                .disabled(actions?.goForward == nil)
            Button("Enclosing Folder") { actions?.goUp?() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(actions?.goUp == nil)
        }
    }
}

struct DiagnosticsCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Copy Diagnostics") { copyDiagnostics() }
        }
    }

    private func copyDiagnostics() {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        Task { @MainActor in
            let report = await model.diagnosticsReport(appVersion: version)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
            let alert = NSAlert()
            alert.messageText = String(localized: "Diagnostics Copied")
            alert.informativeText = String(localized: "Paste them into your bug report. They don’t include file names.")
            alert.runModal()
        }
    }
}
