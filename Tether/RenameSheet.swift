import SwiftUI
import MTPKit

/// Rename for the icon view (the list renames in place).
struct RenameSheet: View {
    let entry: FileEntry
    let onCommit: (String) -> Void
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(entry: FileEntry, onCommit: @escaping (String) -> Void) {
        self.entry = entry
        self.onCommit = onCommit
        _name = State(initialValue: entry.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename “\(entry.name)”").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func commit() {
        onCommit(name)
        dismiss()
    }
}
