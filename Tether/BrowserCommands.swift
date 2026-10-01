import SwiftUI
import TetherCore

/// What the focused browser can do right now; `nil` members disable their menu items.
struct BrowserActions {
    var newFolder: () -> Void
    var refresh: () -> Void
    var goUp: (() -> Void)?
    var open: (() -> Void)?
    var download: (() -> Void)?
    var rename: (() -> Void)?
    var delete: (() -> Void)?
}

extension FocusedValues {
    @Entry var browserActions: BrowserActions?
}

struct BrowserCommands: Commands {
    @FocusedValue(\.browserActions) private var actions
    @AppStorage(SettingsKey.showHiddenFiles) private var showHiddenFiles = false
    @AppStorage(SettingsKey.viewMode) private var viewMode = BrowserViewMode.list

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Folder") { actions?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Divider()
            Button("Open") { actions?.open?() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(actions?.open == nil)
            Button("Download") { actions?.download?() }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(actions?.download == nil)
            Button("Rename") { actions?.rename?() }
                .disabled(actions?.rename == nil)
            Button("Delete…") { actions?.delete?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(actions?.delete == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("as Icons") { viewMode = .icons }
                .keyboardShortcut("1")
            Button("as List") { viewMode = .list }
                .keyboardShortcut("2")
            Divider()
            Button("Refresh") { actions?.refresh() }
                .keyboardShortcut("r")
                .disabled(actions == nil)
            Toggle("Show Hidden Files", isOn: $showHiddenFiles)
                .keyboardShortcut(".", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            Button("Enclosing Folder") { actions?.goUp?() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(actions?.goUp == nil)
        }
    }
}
