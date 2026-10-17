import ServiceManagement
import SwiftUI
import TetherCore

struct SettingsView: View {
    let updater: Updater
    let autoOpen: AutoOpenController? // nil in fake mode: no toggle, no SMAppService access
    @AppStorage(SettingsKey.downloadFolderPath) private var downloadFolderPath = AppSettings.defaultDownloadFolder.path
    @AppStorage(SettingsKey.conflictDefault) private var conflictDefault = ConflictDefault.ask
    @AppStorage(SettingsKey.showHiddenFiles) private var showHiddenFiles = false
    @State private var autoChecks = false

    var body: some View {
        Form {
            LabeledContent("Download to") {
                HStack {
                    Text(AppSettings.downloadFolder().lastPathComponent)
                        .help(AppSettings.downloadFolder().path)
                    Button("Choose…", action: chooseFolder)
                }
            }
            Picker("When a name already exists", selection: $conflictDefault) {
                ForEach(ConflictDefault.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Show hidden files", isOn: $showHiddenFiles)
            Toggle("Check for updates automatically", isOn: Binding(
                get: { autoChecks },
                set: { autoChecks = $0; updater.updater.automaticallyChecksForUpdates = $0 }))
                .disabled(!updater.isStarted)
            if let autoOpen {
                autoOpenSettings(autoOpen)
            }
        }
        .onAppear {
            autoChecks = updater.isStarted && updater.updater.automaticallyChecksForUpdates
            autoOpen?.refresh() // the user may have changed it in System Settings
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func autoOpenSettings(_ autoOpen: AutoOpenController) -> some View {
        Toggle(isOn: Binding(
            get: { autoOpen.isOn },
            set: { on in Task { await autoOpen.setEnabled(on) } })) {
            Text("Open Tether when a phone connects")
            // Ad-hoc builds: after an update macOS won't start the helper until the next login (see the design doc).
            Text("After Tether updates, this works again once you restart your Mac.")
        }
        if autoOpen.state == .needsApproval {
            LabeledContent {
                Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            } label: {
                Text("Allow Tether in Login Items to finish turning this on.")
            }
        }
        if let error = autoOpen.lastError {
            Text(error)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = AppSettings.downloadFolder()
        panel.prompt = String(localized: "Choose")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            downloadFolderPath = url.path
        }
    }
}
