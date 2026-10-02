import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers
import MTPKit
import TetherCore

/// What the file list asks its owner to do. All closures run on the main actor.
struct FileTableActions {
    var open: (FileEntry) -> Void
    var dropFiles: ([URL], NSWindow?) -> Void
    var makePromise: (FileEntry) -> NSFilePromiseProvider
    var requestRename: (FileEntry) -> Void
    var commitRename: (FileEntry, String) -> Void
    /// Called once the requested rename has started, so the owner can clear its request.
    var renameStarted: () -> Void
    var editingChanged: (Bool) -> Void
    var download: ([FileEntry]) -> Void
    var delete: ([FileEntry]) -> Void
    var newFolder: () -> Void
    var quickLook: ([FileEntry]) -> Void
}

/// Finder-style list backed by NSTableView: sortable columns, selection by object ID, inline rename,
/// context menu, drag-out via file promises, drop-in of Finder files.
struct FileTableView: NSViewRepresentable {
    var entries: [FileEntry]
    @Binding var selection: Set<UInt32>
    /// Object whose name should be edited as soon as its row exists.
    var renameRequest: UInt32?
    /// Identity of the folder being shown; a change cancels any in-progress rename.
    var folderKey: FolderRef
    var actions: FileTableActions

    enum Column: String, CaseIterable {
        case name, size, kind, modified

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

        var title: String {
            switch self {
            case .name: String(localized: "Name")
            case .size: String(localized: "Size")
            case .kind: String(localized: "Kind")
            case .modified: String(localized: "Date Modified")
            }
        }

        var width: CGFloat {
            switch self {
            case .name: 320
            case .size: 90
            case .kind: 140
            case .modified: 170
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTable()
        table.setAccessibilityIdentifier("fileTable")
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            table.addTableColumn(tableColumn)
        }
        table.sortDescriptors = [NSSortDescriptor(key: Column.name.rawValue, ascending: true)]
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openClicked(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.onReturn = { [weak coordinator = context.coordinator] in coordinator?.returnPressed() }
        table.onSpace = { [weak coordinator = context.coordinator] in coordinator?.spacePressed() }
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.folderChanged(to: folderKey)
        coordinator.show(entries)
        coordinator.syncSelectionFromParent()
        coordinator.startRenameIfRequested()
    }

    /// Return starts a rename instead of NSTableView's default handling.
    final class FileTable: NSTableView {
        var onReturn: (@MainActor () -> Void)?
        var onSpace: (@MainActor () -> Void)?

        override func keyDown(with event: NSEvent) {
            let plain = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function]).isEmpty
            if plain, event.keyCode == 36 || event.keyCode == 76, let onReturn {
                onReturn()
                return
            }
            if plain, event.keyCode == 49, let onSpace {
                onSpace()
                return
            }
            super.keyDown(with: event)
        }

        override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
        override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
            MainActor.assumeIsolated { QuickLookController.shared.attach(panel, from: self) }
        }
        override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
            MainActor.assumeIsolated { QuickLookController.shared.detach(panel, from: self) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
        var parent: FileTableView
        weak var table: NSTableView?
        private var source: [FileEntry] = []
        private var rows: [FileEntry] = []
        /// Entries that arrived while a name was being edited; applied when editing ends.
        private var pendingEntries: [FileEntry]?
        /// Programmatic selection changes must not be echoed back into the SwiftUI binding.
        private var isApplyingSelection = false
        private var editingID: UInt32?
        private var editingField: NSTextField?
        private var currentFolderKey: FolderRef?
        private var renameCancelled = false
        private var renameScheduled = false
        private var menuTargets: [FileEntry] = []

        init(parent: FileTableView) { self.parent = parent }

        // MARK: Data

        /// Drops all editing state without committing (the field is gone or the folder changed).
        private func resetEditing(notify: Bool) {
            guard editingID != nil else { return }
            editingID = nil
            editingField?.isEditable = false
            editingField = nil
            renameCancelled = false
            pendingEntries = nil
            if notify {
                Task { @MainActor [weak self] in self?.parent.actions.editingChanged(false) }
            }
        }

        func folderChanged(to key: FolderRef) {
            defer { currentFolderKey = key }
            guard let old = currentFolderKey, old != key else { return }
            let field = editingField
            resetEditing(notify: true) // never commit a rename into a different folder
            if field?.currentEditor() != nil { table?.window?.makeFirstResponder(table) }
        }

        func show(_ entries: [FileEntry]) {
            if editingID != nil, editingField?.currentEditor() == nil {
                resetEditing(notify: true) // the editor went away without telling us
            }
            if editingID != nil {
                pendingEntries = entries
                return
            }
            guard entries != source else { return }
            source = entries
            resort()
        }

        private func resort() {
            let descriptor = table?.sortDescriptors.first
            let key = descriptor?.key ?? Column.name.rawValue
            let ascending = descriptor?.ascending ?? true
            // One description per entry (not per comparison) when sorting by kind.
            let kinds: [UInt32: String] = key == Column.kind.rawValue
                ? Dictionary(source.map { ($0.objectID, FileKind.description(for: $0)) }, uniquingKeysWith: { first, _ in first })
                : [:]
            func less(_ a: FileEntry, _ b: FileEntry) -> Bool {
                switch key {
                case Column.kind.rawValue:
                    // Different strings can still compare equal (e.g. by case); fall back to the name then too.
                    let c = (kinds[a.objectID] ?? "").localizedStandardCompare(kinds[b.objectID] ?? "")
                    return c != .orderedSame
                        ? c == .orderedAscending
                        : a.name.localizedStandardCompare(b.name) == .orderedAscending
                case Column.size.rawValue:
                    return a.size != b.size ? a.size < b.size : a.name.localizedStandardCompare(b.name) == .orderedAscending
                case Column.modified.rawValue:
                    return (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
                default:
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
            rows = source.sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder } // folders first, like Finder
                return ascending ? less(a, b) : less(b, a)
            }
            isApplyingSelection = true
            table?.reloadData()
            isApplyingSelection = false
            applySelection()
        }

        // MARK: Selection (by object ID)

        private var selectedIDsInTable: Set<UInt32> {
            guard let table else { return [] }
            return Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].objectID : nil })
        }

        private func applySelection() {
            guard let table else { return }
            let indexes = IndexSet(rows.indices.filter { parent.selection.contains(rows[$0].objectID) })
            isApplyingSelection = true
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            isApplyingSelection = false
        }

        func syncSelectionFromParent() {
            if selectedIDsInTable != parent.selection { applySelection() }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection else { return }
            let ids = selectedIDsInTable
            if ids != parent.selection { parent.selection = ids }
        }

        private var selectedEntries: [FileEntry] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        }

        // MARK: Table data source / delegate

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let entry = rows[row]
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView)
                ?? makeCell(column)
            switch column {
            case .name:
                cell.textField?.stringValue = entry.name
                cell.setAccessibilityLabel(AccessibilityText.file(entry))
                cell.setAccessibilityIdentifier(entry.name)
                // The table's AX cell proxy doesn't forward the identifier, so the name text carries it too (UI tests).
                cell.textField?.setAccessibilityIdentifier(entry.name)
                cell.imageView?.image = icon(for: entry)
            case .size:
                cell.textField?.stringValue = entry.isFolder
                    ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file)
            case .kind:
                cell.textField?.stringValue = FileKind.description(for: entry)
            case .modified:
                cell.textField?.stringValue = entry.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—"
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            if editingID != nil { // like Finder: clicking elsewhere commits the edit first
                tableView.window?.makeFirstResponder(tableView)
                if editingID != nil { resetEditing(notify: true) }
            }
            resort()
        }

        @objc func openClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard rows.indices.contains(row) else { return }
            parent.actions.open(rows[row])
        }

        // MARK: Rename

        func spacePressed() {
            guard editingID == nil else { return }
            parent.actions.quickLook(selectedEntries)
        }

        func returnPressed() {
            let selected = selectedEntries
            guard editingID == nil, selected.count == 1 else { return }
            parent.actions.requestRename(selected[0])
        }

        /// Starts the owner's pending rename on the next run loop turn (never during a SwiftUI update).
        func startRenameIfRequested() {
            guard let id = parent.renameRequest, !renameScheduled,
                  rows.contains(where: { $0.objectID == id }) else { return }
            renameScheduled = true
            Task { @MainActor [weak self] in // next main-actor turn, outside the SwiftUI update
                guard let self else { return }
                self.renameScheduled = false
                self.parent.actions.renameStarted()
                self.beginEditing(objectID: id)
            }
        }

        private func beginEditing(objectID: UInt32) {
            guard let table, let row = rows.firstIndex(where: { $0.objectID == objectID }) else { return }
            let nameColumn = table.column(withIdentifier: Column.name.identifier)
            guard nameColumn >= 0 else { return }
            table.scrollRowToVisible(row)
            table.selectRowIndexes([row], byExtendingSelection: false)
            guard let cell = table.view(atColumn: nameColumn, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField else { return }
            field.isEditable = true
            field.delegate = self
            guard table.window?.makeFirstResponder(field) == true else {
                field.isEditable = false
                return
            }
            editingID = objectID
            editingField = field
            renameCancelled = false
            let name = rows[row].name as NSString
            let base = rows[row].isFolder ? name : name.deletingPathExtension as NSString
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: base.length)
            parent.actions.editingChanged(true)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                renameCancelled = true
                control.window?.makeFirstResponder(table) // ends editing → controlTextDidEndEditing
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, let id = editingID else { return }
            editingID = nil
            editingField = nil
            let typed = field.stringValue
            field.isEditable = false
            let entry = source.first { $0.objectID == id }
            if let entry { field.stringValue = entry.name } // the refresh after a successful rename shows the new name
            parent.actions.editingChanged(false)
            if !renameCancelled, let entry { parent.actions.commitRename(entry, typed) }
            renameCancelled = false
            if let pending = pendingEntries {
                pendingEntries = nil
                show(pending)
            }
            if table?.window?.firstResponder !== table { table?.window?.makeFirstResponder(table) }
            startRenameIfRequested()
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, editingID == nil else { return }
            let clicked = table.clickedRow
            if rows.indices.contains(clicked) {
                if !table.selectedRowIndexes.contains(clicked) {
                    table.selectRowIndexes([clicked], byExtendingSelection: false) // Finder: right-click selects
                }
                menuTargets = selectedEntries
            } else {
                menuTargets = []
            }
            let targets = menuTargets
            if !targets.isEmpty {
                if targets.count == 1, targets[0].isFolder {
                    menu.addItem(item(String(localized: "Open"), #selector(openFromMenu)))
                }
                menu.addItem(item(targets.count == 1 ? String(localized: "Download")
                                                     : String(localized: "Download \(targets.count) Items"),
                                  #selector(downloadFromMenu)))
                menu.addItem(.separator())
                if targets.count == 1 { menu.addItem(item(String(localized: "Rename"), #selector(renameFromMenu))) }
                menu.addItem(item(targets.count == 1 ? String(localized: "Delete…")
                                                     : String(localized: "Delete \(targets.count) Items…"),
                                  #selector(deleteFromMenu)))
                menu.addItem(.separator())
            }
            menu.addItem(item(String(localized: "New Folder"), #selector(newFolderFromMenu)))
        }

        private func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            // Stable identifier ("download", "rename", …) so UI tests don't depend on selector names.
            item.identifier = NSUserInterfaceItemIdentifier(NSStringFromSelector(action).replacingOccurrences(of: "FromMenu", with: ""))
            return item
        }

        @objc private func openFromMenu() { if let entry = menuTargets.first { parent.actions.open(entry) } }
        @objc private func downloadFromMenu() { parent.actions.download(menuTargets) }
        @objc private func renameFromMenu() { if let entry = menuTargets.first { parent.actions.requestRename(entry) } }
        @objc private func deleteFromMenu() { parent.actions.delete(menuTargets) }
        @objc private func newFolderFromMenu() { parent.actions.newFolder() }

        // MARK: Drag out

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            parent.actions.makePromise(rows[row])
        }

        // MARK: Drop in

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            if (info.draggingSource as? NSTableView) === tableView { return [] }
            guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                        options: [.urlReadingFileURLsOnly: true]) else { return [] }
            tableView.setDropRow(-1, dropOperation: .on) // whole table = current folder
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                                 options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  !urls.isEmpty else { return false }
            parent.actions.dropFiles(urls, tableView.window)
            return true
        }

        // MARK: Cells

        private func makeCell(_ column: Column) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = column.identifier
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            if column == .name {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                image.setAccessibilityElement(false)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                ])
            } else {
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
                if column == .size { text.alignment = .right }
            }
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func icon(for entry: FileEntry) -> NSImage {
            let type: UTType = entry.isFolder
                ? .folder
                : UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
            return NSWorkspace.shared.icon(for: type)
        }
    }
}
