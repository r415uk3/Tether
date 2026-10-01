import SwiftUI
import MTPKit
import TetherCore

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    let selection: StorageSelection
    @State private var path: [FileEntry] = []
    /// The connection session `path` was built in; its handles mean nothing in any other session.
    @State private var pathSession: UUID?
    @State private var selectedIDs: Set<UInt32> = []
    @State private var renameRequest: UInt32?
    @State private var isEditingName = false
    /// Folder and its entries as they were when the current rename began.
    @State private var renameContext: (folder: FolderRef, siblings: [FileEntry])?
    @State private var pendingDelete: [FileEntry] = []
    @State private var problem: String?
    @AppStorage(SettingsKey.showHiddenFiles) private var showHiddenFiles = false
    @AppStorage(SettingsKey.viewMode) private var viewMode = BrowserViewMode.list
    @State private var renamingEntry: FileEntry?

    private var session: UUID? { model.devices.session(for: selection.deviceID) }

    private var folder: FolderRef {
        FolderRef(deviceID: selection.deviceID, storageID: selection.storageID,
                  folderID: (pathSession == session ? path.last?.objectID : nil) ?? FileEntry.rootID,
                  session: session)
    }

    private var title: String {
        path.last?.name ?? model.devices.storage(for: folder)?.name ?? String(localized: "Phone")
    }

    /// Every entry, hidden ones included (used for name-clash checks).
    private var allEntries: [FileEntry] { model.devices.listings[folder]?.entries ?? [] }
    private var visibleEntries: [FileEntry] { EntryFilter.visible(allEntries, showHidden: showHiddenFiles) }
    private var selectedEntries: [FileEntry] { visibleEntries.filter { selectedIDs.contains($0.objectID) } }

    var body: some View {
        let listing = model.devices.listings[folder]
        Group {
            switch viewMode {
            case .icons:
                FileGridView(entries: visibleEntries, selection: $selectedIDs, folderKey: folder,
                             thumbnailVersion: model.thumbnails.version,
                             thumbnail: { entry in
                                 model.thumbnails.cached(entry, deviceID: selection.deviceID).flatMap(NSImage.init(data:))
                             },
                             requestThumbnail: { model.thumbnails.request($0, in: folder) },
                             actions: tableActions)
            case .list:
                FileTableView(entries: visibleEntries, selection: $selectedIDs, renameRequest: renameRequest,
                              folderKey: folder, actions: tableActions)
            }
        }
            .overlay { overlay(for: listing) }
            .navigationTitle(title)
            .navigationSubtitle(listing?.isUpdating == true ? String(localized: "Updating…") : "")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: goUp) { Label("Back", systemImage: "chevron.left") }
                        .disabled(path.isEmpty || isEditingName)
                }
                ToolbarItem {
                    Picker("View", selection: $viewMode) {
                        Label("Icons", systemImage: "square.grid.2x2").tag(BrowserViewMode.icons)
                        Label("List", systemImage: "list.bullet").tag(BrowserViewMode.list)
                    }
                    .pickerStyle(.segmented)
                    .help("Show items as icons or as a list")
                }
                ToolbarItem {
                    Button(action: refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                ToolbarItem {
                    Button(action: newFolder) { Label("New Folder", systemImage: "folder.badge.plus") }
                }
                ToolbarItem {
                    Button(action: chooseFilesToUpload) { Label("Upload", systemImage: "square.and.arrow.up") }
                }
            }
            .task(id: folder) { await model.devices.refresh(folder) }
            .onChange(of: folder) {
                selectedIDs = []
                renameRequest = nil
            }
            .onChange(of: session) { path = [] }
            .focusedSceneValue(\.browserActions, menuActions)
            .confirmationDialog(deleteTitle, isPresented: isConfirmingDelete) {
                let items = pendingDelete
                Button(String(localized: "Delete"), role: .destructive) { delete(items) }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text("This can’t be undone.")
            }
            .alert(String(localized: "The Operation Couldn’t Be Completed"), isPresented: isShowingProblem) {
                Button(String(localized: "OK")) {}
            } message: {
                Text(problem ?? "")
            }
            .sheet(item: $renamingEntry) { entry in
                RenameSheet(entry: entry) { commitRename(entry, $0) }
            }
            .onChange(of: renamingEntry) { isEditingName = renamingEntry != nil }
    }

    // MARK: Overlay

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
                Button("Try Again", action: refresh)
            }
        } else if visibleEntries.isEmpty {
            ContentUnavailableView("Empty Folder", systemImage: "folder",
                                   description: Text("Drop files here to copy them to the phone."))
                .allowsHitTesting(false)
        }
    }

    // MARK: Table wiring

    private var tableActions: FileTableActions {
        FileTableActions(
            open: open,
            dropFiles: { upload($0, window: $1) },
            makePromise: { FilePromise.provider(for: $0, deviceID: selection.deviceID, queue: model.transfers) },
            requestRename: beginRename,
            commitRename: commitRename,
            renameStarted: { renameRequest = nil },
            editingChanged: { editing in
                isEditingName = editing
                if editing { renameContext = (folder, allEntries) }
            },
            download: download,
            delete: requestDelete,
            newFolder: newFolder)
    }

    private var menuActions: BrowserActions {
        let selected = selectedEntries
        let editing = isEditingName
        // Navigating away mid-rename would discard the typed name.
        let goUpAction: (() -> Void)? = path.isEmpty || editing ? nil : { goUp() }
        let openAction: (() -> Void)? =
            selected.count == 1 && selected[0].isFolder && !editing ? { open(selected[0]) } : nil
        let downloadAction: (() -> Void)? = selected.isEmpty ? nil : { download(selected) }
        let renameAction: (() -> Void)? =
            selected.count == 1 && !editing ? { beginRename(selected[0]) } : nil
        let deleteAction: (() -> Void)? = selected.isEmpty || editing ? nil : { requestDelete(selected) }
        return BrowserActions(
            newFolder: newFolder, refresh: refresh, goUp: goUpAction, open: openAction,
            download: downloadAction, rename: renameAction, delete: deleteAction)
    }

    // MARK: Actions

    private func goUp() {
        if !path.isEmpty { path.removeLast() }
    }

    private func refresh() {
        let folder = self.folder
        Task { await model.devices.refresh(folder) }
    }

    private func open(_ entry: FileEntry) {
        if entry.isFolder {
            pathSession = session
            path.append(entry)
        }
    }

    private func newFolder() {
        let name = NameValidation.newFolderName(siblings: allEntries)
        let folder = self.folder
        Task {
            do {
                let created = try await model.devices.createFolder(named: name, in: folder)
                selectedIDs = [created.objectID]
                beginRename(created)
            } catch {
                problem = MTPError.from(error).localizedDescription
            }
        }
    }

    private func beginRename(_ entry: FileEntry) {
        switch viewMode {
        case .list:
            renameRequest = entry.objectID
        case .icons:
            renameContext = (folder, allEntries)
            renamingEntry = entry
        }
    }

    private func commitRename(_ entry: FileEntry, _ proposed: String) {
        let context = renameContext ?? (folder, allEntries)
        switch NameValidation.validate(proposed, current: entry.name, siblings: context.siblings) {
        case .unchanged:
            return
        case .invalid(let reason):
            problem = reason.message
        case .valid(let name):
            let folder = context.folder
            Task {
                do { try await model.devices.rename(entry, in: folder, to: name) }
                catch { problem = MTPError.from(error).localizedDescription }
            }
        }
    }

    private func requestDelete(_ entries: [FileEntry]) {
        if !entries.isEmpty { pendingDelete = entries }
    }

    private func delete(_ entries: [FileEntry]) {
        pendingDelete = []
        let folder = self.folder
        Task {
            do {
                try await model.devices.delete(entries, in: folder)
                selectedIDs.subtract(entries.map(\.objectID))
            } catch {
                problem = MTPError.from(error).localizedDescription
            }
        }
    }

    private func download(_ entries: [FileEntry]) {
        let directory = AppSettings.downloadFolder()
        for entry in entries {
            model.transfers.enqueueDownload(entry, deviceID: selection.deviceID, into: directory)
        }
    }

    private func upload(_ urls: [URL], window: NSWindow?) {
        let folder = self.folder
        let names = Set(allEntries.map(\.name)) // hidden names clash too
        let defaultChoice = AppSettings.conflictDefault().choice
        Task {
            let planned = await UploadPlanner.plan(urls, existingNames: names, defaultChoice: defaultChoice,
                                                   ask: { await ConflictPrompt.ask($0, in: window) })
            for item in planned {
                model.transfers.enqueueUpload(item.url, to: folder, conflict: item.conflict)
            }
        }
    }

    private func chooseFilesToUpload() {
        let window = NSApp.mainWindow
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Upload")
        panel.begin { response in
            guard response == .OK else { return }
            upload(panel.urls, window: window)
        }
    }

    // MARK: Dialog state

    private var deleteTitle: String {
        pendingDelete.count == 1
            ? String(localized: "Delete “\(pendingDelete[0].name)”?")
            : String(localized: "Delete \(pendingDelete.count) items?")
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })
    }

    private var isShowingProblem: Binding<Bool> {
        Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
    }
}
