import SwiftUI
import MTPKit
import TetherCore

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    let selection: StorageSelection
    @Binding var path: [FileEntry]

    private var folder: FolderRef {
        FolderRef(deviceID: selection.deviceID, storageID: selection.storageID,
                  folderID: path.last?.objectID ?? FileEntry.rootID)
    }

    private var title: String {
        path.last?.name ?? model.devices.storage(for: folder)?.name ?? String(localized: "Phone")
    }

    var body: some View {
        let listing = model.devices.listings[folder]
        FileTableView(entries: listing?.entries ?? [],
                      onOpen: open,
                      onDropFiles: upload,
                      makePromise: { FilePromise.provider(for: $0, deviceID: selection.deviceID, queue: model.transfers) })
            .overlay { overlay(for: listing) }
            .navigationTitle(title)
            .navigationSubtitle(listing?.isUpdating == true ? String(localized: "Updating…") : "")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { path.removeLast() } label: { Label("Back", systemImage: "chevron.left") }
                        .disabled(path.isEmpty)
                        .keyboardShortcut(.upArrow, modifiers: .command)
                }
                ToolbarItem {
                    Button { Task { await model.devices.refresh(folder) } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r")
                }
                ToolbarItem {
                    Button(action: chooseFilesToUpload) { Label("Upload", systemImage: "square.and.arrow.up") }
                }
                ToolbarItem { TransfersButton() }
            }
            .task(id: folder) { await model.devices.refresh(folder) }
    }

    @ViewBuilder
    private func overlay(for listing: DeviceStore.Listing?) -> some View {
        if listing == nil || (listing!.isUpdating && listing!.entries.isEmpty) {
            ProgressView()
        } else if let error = listing?.error, listing?.entries.isEmpty == true {
            ContentUnavailableView {
                Label("Can’t Read This Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("Try Again") { Task { await model.devices.refresh(folder) } }
            }
        } else if listing?.entries.isEmpty == true {
            ContentUnavailableView("Empty Folder", systemImage: "folder",
                                   description: Text("Drop files here to copy them to the phone."))
                .allowsHitTesting(false)
        }
    }

    private func open(_ entry: FileEntry) {
        if entry.isFolder { path.append(entry) }
    }

    private func upload(_ urls: [URL]) {
        for url in urls { model.transfers.enqueueUpload(url, to: folder) }
    }

    private func chooseFilesToUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Upload")
        panel.begin { response in
            guard response == .OK else { return }
            upload(panel.urls)
        }
    }
}
