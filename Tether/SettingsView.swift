import SwiftUI
import TetherCore

struct SettingsView: View {
    @AppStorage(SettingsKey.downloadFolderPath) private var downloadFolderPath = AppSettings.defaultDownloadFolder.path
    @AppStorage(SettingsKey.conflictDefault) private var conflictDefault = ConflictDefault.ask
    @AppStorage(SettingsKey.showHiddenFiles) private var showHiddenFiles = false

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
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
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
