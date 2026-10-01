import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MTPKit

/// Finder-style icon view backed by NSCollectionView, sharing the list's actions.
struct FileGridView: NSViewRepresentable {
    var entries: [FileEntry]
    @Binding var selection: Set<UInt32>
    var folderKey: FolderRef
    /// Changes whenever new thumbnails arrive.
    var thumbnailVersion: Int
    var thumbnail: (FileEntry) -> NSImage?
    var requestThumbnail: (FileEntry) -> Void
    var actions: FileTableActions

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 104, height: 112)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let grid = FileGrid()
        grid.collectionViewLayout = layout
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.backgroundColors = [.clear]
        grid.register(FileGridItem.self, forItemWithIdentifier: FileGridItem.identifier)
        grid.dataSource = context.coordinator
        grid.delegate = context.coordinator
        grid.registerForDraggedTypes([.fileURL])
        grid.setDraggingSourceOperationMask(.copy, forLocal: false)
        let coordinator = context.coordinator
        grid.onDoubleClick = { [weak coordinator] path in coordinator?.open(at: path) }
        grid.onReturn = { [weak coordinator] in coordinator?.returnPressed() }
        let menu = NSMenu()
        menu.delegate = coordinator
        grid.menu = menu
        coordinator.grid = grid

        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        coordinator.observeScrolling(of: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.folderChanged(to: folderKey)
        coordinator.show(entries)
        coordinator.syncSelectionFromParent()
        coordinator.refreshThumbnails(version: thumbnailVersion)
    }

    /// Double-click and Return handling plus the clicked item for the context menu.
    final class FileGrid: NSCollectionView {
        var onDoubleClick: (@MainActor (IndexPath) -> Void)?
        var onReturn: (@MainActor () -> Void)?
        private(set) var menuIndexPath: IndexPath?

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            if event.clickCount == 2, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
                onDoubleClick?(path)
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            menuIndexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil))
            return super.menu(for: event)
        }

        override func keyDown(with event: NSEvent) {
            let plain = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function]).isEmpty
            if plain, event.keyCode == 36 || event.keyCode == 76, let onReturn {
                onReturn()
                return
            }
            super.keyDown(with: event)
        }
    }

    final class FileGridItem: NSCollectionViewItem {
        static let identifier = NSUserInterfaceItemIdentifier("FileGridItem")

        /// True once the item shows a phone thumbnail, so refreshes skip it.
        var hasThumbnail = false

        override func loadView() {
            let root = NSView()
            root.wantsLayer = true
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyUpOrDown
            image.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(wrappingLabelWithString: "")
            label.alignment = .center
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byCharWrapping
            label.cell?.truncatesLastVisibleLine = true
            label.font = .systemFont(ofSize: 12)
            label.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(image)
            root.addSubview(label)
            NSLayoutConstraint.activate([
                image.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
                image.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                image.widthAnchor.constraint(equalToConstant: 64),
                image.heightAnchor.constraint(equalToConstant: 64),
                label.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 4),
                label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            ])
            view = root
            imageView = image
            textField = label
        }

        override var isSelected: Bool { didSet { updateHighlight() } }
        override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateHighlight() } }

        private func updateHighlight() {
            let on = isSelected || highlightState == .forSelection
            view.layer?.cornerRadius = 8
            view.layer?.backgroundColor = on
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3).cgColor : nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSMenuDelegate {
        var parent: FileGridView
        weak var grid: NSCollectionView?
        private var rows: [FileEntry] = []
        private var folderKey: FolderRef?
        private var isApplyingSelection = false
        private var thumbnailVersion = -1
        private var menuTargets: [FileEntry] = []
        private var lastEntries: [FileEntry]?
        private var isLiveScrolling = false

        func observeScrolling(of scroll: NSScrollView) {
            NotificationCenter.default.addObserver(self, selector: #selector(liveScrollStarted),
                                                   name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            NotificationCenter.default.addObserver(self, selector: #selector(liveScrollEnded),
                                                   name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        }

        @objc private func liveScrollStarted() { isLiveScrolling = true }

        @objc private func liveScrollEnded() {
            isLiveScrolling = false
            requestVisibleThumbnails()
        }

        /// Only visible items are worth a phone round-trip; the queue is FIFO.
        private func requestVisibleThumbnails() {
            guard let grid else { return }
            for case let item as FileGridItem in grid.visibleItems() {
                guard !item.hasThumbnail, let path = grid.indexPath(for: item), rows.indices.contains(path.item) else { continue }
                parent.requestThumbnail(rows[path.item])
            }
        }

        init(parent: FileGridView) { self.parent = parent }

        // MARK: Data

        func folderChanged(to key: FolderRef) {
            guard key != folderKey else { return }
            folderKey = key
            grid?.scroll(.zero)
        }

        func show(_ entries: [FileEntry]) {
            guard entries != lastEntries else { return }
            lastEntries = entries
            let sorted = entries.sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            guard sorted != rows else { return }
            rows = sorted
            isApplyingSelection = true
            grid?.reloadData()
            isApplyingSelection = false
            applySelection()
        }

        func refreshThumbnails(version: Int) {
            guard version != thumbnailVersion, let grid else { return }
            thumbnailVersion = version
            for case let item as FileGridItem in grid.visibleItems() {
                guard let path = grid.indexPath(for: item), rows.indices.contains(path.item) else { continue }
                guard !item.hasThumbnail, let thumb = parent.thumbnail(rows[path.item]) else { continue }
                item.imageView?.image = thumb
                item.hasThumbnail = true
            }
        }

        // MARK: Selection (by object ID)

        private var selectedIDs: Set<UInt32> {
            Set((grid?.selectionIndexPaths ?? []).compactMap { rows.indices.contains($0.item) ? rows[$0.item].objectID : nil })
        }

        private var selectedEntries: [FileEntry] {
            (grid?.selectionIndexPaths ?? []).sorted().compactMap { rows.indices.contains($0.item) ? rows[$0.item] : nil }
        }

        private func applySelection() {
            guard let grid else { return }
            let paths = Set(rows.indices.filter { parent.selection.contains(rows[$0].objectID) }
                .map { IndexPath(item: $0, section: 0) })
            isApplyingSelection = true
            grid.selectionIndexPaths = paths
            isApplyingSelection = false
        }

        func syncSelectionFromParent() {
            if selectedIDs != parent.selection { applySelection() }
        }

        private func selectionChanged() {
            guard !isApplyingSelection else { return }
            let ids = selectedIDs
            if ids != parent.selection { parent.selection = ids }
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged()
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged()
        }

        // MARK: Items

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: FileGridItem.identifier, for: indexPath)
            let entry = rows[indexPath.item]
            item.textField?.stringValue = entry.name
            let thumb = parent.thumbnail(entry)
            item.imageView?.image = thumb ?? icon(for: entry)
            (item as? FileGridItem)?.hasThumbnail = thumb != nil
            if thumb == nil, !isLiveScrolling { parent.requestThumbnail(entry) }
            return item
        }

        private func icon(for entry: FileEntry) -> NSImage {
            let type: UTType = entry.isFolder
                ? .folder
                : UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
            return NSWorkspace.shared.icon(for: type)
        }

        func open(at path: IndexPath) {
            guard rows.indices.contains(path.item) else { return }
            parent.actions.open(rows[path.item])
        }

        func returnPressed() {
            let selected = selectedEntries
            if selected.count == 1 { parent.actions.requestRename(selected[0]) }
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let grid = grid as? FileGrid else { return }
            if let path = grid.menuIndexPath, rows.indices.contains(path.item) {
                if !grid.selectionIndexPaths.contains(path) {
                    grid.selectionIndexPaths = [path] // Finder: right-click selects
                    selectionChanged()
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
            return item
        }

        @objc private func openFromMenu() { if let entry = menuTargets.first { parent.actions.open(entry) } }
        @objc private func downloadFromMenu() { parent.actions.download(menuTargets) }
        @objc private func renameFromMenu() { if let entry = menuTargets.first { parent.actions.requestRename(entry) } }
        @objc private func deleteFromMenu() { parent.actions.delete(menuTargets) }
        @objc private func newFolderFromMenu() { parent.actions.newFolder() }

        // MARK: Drag out / drop in

        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>,
                            with event: NSEvent) -> Bool { true }

        func collectionView(_ collectionView: NSCollectionView,
                            pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            rows.indices.contains(indexPath.item) ? parent.actions.makePromise(rows[indexPath.item]) : nil
        }

        func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                            proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                            dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>)
            -> NSDragOperation {
            if (draggingInfo.draggingSource as? NSCollectionView) === collectionView { return [] }
            guard draggingInfo.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                                options: [.urlReadingFileURLsOnly: true]) else { return [] }
            proposedDropOperation.pointee = .before // the whole folder is the target
            return .copy
        }

        func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                            indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
            guard let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  !urls.isEmpty else { return false }
            parent.actions.dropFiles(urls, collectionView.window)
            return true
        }
    }
}
