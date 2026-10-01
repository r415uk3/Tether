import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MTPKit

/// Finder-style list backed by NSTableView: sortable columns, multi-select,
/// drag-out via file promises, drop-in of Finder files.
struct FileTableView: NSViewRepresentable {
    var entries: [FileEntry]
    var onOpen: (FileEntry) -> Void
    var onDropFiles: ([URL]) -> Void
    var makePromise: (FileEntry) -> NSFilePromiseProvider

    enum Column: String, CaseIterable {
        case name, size, modified

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

        var title: String {
            switch self {
            case .name: String(localized: "Name")
            case .size: String(localized: "Size")
            case .modified: String(localized: "Date Modified")
            }
        }

        var width: CGFloat {
            switch self {
            case .name: 320
            case .size: 90
            case .modified: 170
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
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
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.show(entries)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: FileTableView
        weak var table: NSTableView?
        private var source: [FileEntry] = []
        private var rows: [FileEntry] = []

        init(parent: FileTableView) { self.parent = parent }

        func show(_ entries: [FileEntry]) {
            guard entries != source else { return }
            source = entries
            resort()
        }

        private func resort() {
            let descriptor = table?.sortDescriptors.first
            let key = descriptor?.key ?? Column.name.rawValue
            let ascending = descriptor?.ascending ?? true
            func less(_ a: FileEntry, _ b: FileEntry) -> Bool {
                switch key {
                case Column.size.rawValue:
                    a.size != b.size ? a.size < b.size : a.name.localizedStandardCompare(b.name) == .orderedAscending
                case Column.modified.rawValue:
                    (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
                default:
                    a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
            rows = source.sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder } // folders first, like Finder
                return ascending ? less(a, b) : less(b, a)
            }
            table?.reloadData()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let entry = rows[row]
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView)
                ?? makeCell(column)
            switch column {
            case .name:
                cell.textField?.stringValue = entry.name
                cell.imageView?.image = icon(for: entry)
            case .size:
                cell.textField?.stringValue = entry.isFolder
                    ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file)
            case .modified:
                cell.textField?.stringValue = entry.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—"
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            resort()
        }

        @objc func openClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard rows.indices.contains(row) else { return }
            parent.onOpen(rows[row])
        }

        // MARK: Drag out

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            parent.makePromise(rows[row])
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
            parent.onDropFiles(urls)
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
