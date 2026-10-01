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
    /// Folder the pending delete was requested in (navigating before confirming must not retarget it).
    @State private var pendingDeleteFolder: FolderRef?
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
            .navigationSubtitle(subtitle(for: listing))
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
                    .disabled(isEditingName)
                    .help("Show items as icons or as a list")
                }
                ToolbarItem {
                    Button(action: refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                ToolbarItem {
                    Button(action: newFolder) { Label("New Folder", systemImage: "folder.badge.plus") }
                        .disabled(isEditingName)
                }
                ToolbarItem {
                    Button(action: chooseFilesToUpload) { Label("Upload", systemImage: "square.and.arrow.up") }
                }
            }
            .task(id: folder) { await model.devices.refresh(folder) }
            .onChange(of: folder) {
                QuickLookController.shared.invalidate()
                selectedIDs = []
                renameRequest = nil
            }
            .onChange(of: session) {
                QuickLookController.shared.invalidate()
                path = []
            }
            .onChange(of: selectedIDs) {
                if QuickLookController.shared.isVisible { showQuickLook(selectedEntries) }
            }
            .onChange(of: viewMode) {
                renameRequest = nil
                isEditingName = false
            }
            .focusedSceneValue(\.browserActions, menuActions)
            .confirmationDialog(deleteTitle, isPresented: isConfirmingDelete) {
                let items = pendingDelete
                let deleteFolder = pendingDeleteFolder ?? folder
                Button(String(localized: "Delete"), role: .destructive) { delete(items, in: deleteFolder) }
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
            newFolder: newFolder,
            quickLook: quickLook)
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
        let quickLookAction: (() -> Void)? =
            selected.contains { !$0.isFolder } && !editing ? { quickLook(selected) } : nil
        let newFolderAction: (() -> Void)? = editing ? nil : { newFolder() }
        let showIconsAction: (() -> Void)? = editing ? nil : { viewMode = .icons }
        let showListAction: (() -> Void)? = editing ? nil : { viewMode = .list }
        return BrowserActions(
            newFolder: newFolderAction, refresh: refresh, goUp: goUpAction, open: openAction,
            download: downloadAction, rename: renameAction, delete: deleteAction,
            showIcons: showIconsAction, showList: showListAction, quickLook: quickLookAction)
    }

    // MARK: Actions

    private func subtitle(for listing: DeviceStore.Listing?) -> String {
        if let fraction = model.previews.progress {
            return String(localized: "Preparing preview… \(Int(fraction * 100))%")
        }
        return listing?.isUpdating == true ? String(localized: "Updating…") : ""
    }

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
        } else {
            showQuickLook([entry]) // double-click replaces the preview; it never closes the panel
        }
    }

    private func quickLook(_ entries: [FileEntry]) {
        QuickLookController.shared.toggle(entries, deviceID: selection.deviceID, cache: model.previews) { error in
            problem = error.localizedDescription
        }
    }

    private func showQuickLook(_ entries: [FileEntry]) {
        QuickLookController.shared.show(entries, deviceID: selection.deviceID, cache: model.previews) { error in
            problem = error.localizedDescription
        }
    }

    private func newFolder() {
        let name = NameValidation.newFolderName(siblings: allEntries)
        let folder = self.folder
        Task {
            do {
                let created = try await model.devices.createFolder(named: name, in: folder)
                guard self.folder == folder else { return }
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
        if !entries.isEmpty {
            pendingDeleteFolder = folder
            pendingDelete = entries
        }
    }

    private func delete(_ entries: [FileEntry], in folder: FolderRef) {
        pendingDelete = []
        pendingDeleteFolder = nil
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
        Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = []; pendingDeleteFolder = nil } })
    }

    private var isShowingProblem: Binding<Bool> {
        Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
    }
}
