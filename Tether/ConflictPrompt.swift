import AppKit
import TetherCore

/// Finder-style "an item with this name already exists" alert, shown as a sheet on the key window.
@MainActor
enum ConflictPrompt {
    static func ask(_ question: ConflictQuestion) async -> ConflictAnswer {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "An item named “\(question.name)” already exists in this folder.")
        alert.informativeText = String(localized: "Do you want to replace it with the one you’re copying?")
        alert.addButton(withTitle: String(localized: "Replace"))   // .alertFirstButtonReturn
        alert.addButton(withTitle: String(localized: "Keep Both")) // .alertSecondButtonReturn
        let skip = alert.addButton(withTitle: String(localized: "Skip"))
        skip.keyEquivalent = "\u{1b}" // Esc skips
        if question.remaining > 0 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "Apply to all")
        }

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        let choice: ConflictChoice = switch response {
        case .alertFirstButtonReturn: .replace
        case .alertSecondButtonReturn: .keepBoth
        default: .skip
        }
        return ConflictAnswer(choice: choice, applyToAll: alert.suppressionButton?.state == .on)
    }
}
