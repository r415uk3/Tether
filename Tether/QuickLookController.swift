import AppKit
import Quartz
import MTPKit
import TetherCore

/// Feeds QLPreviewPanel with phone files downloaded into the preview cache.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var urls: [URL] = []
    private var latestRequest = 0
    /// The request whose downloads are still running, if any.
    private var pendingRequest: Int?
    /// The list or grid that currently controls the panel; key events are forwarded to it.
    private weak var controllingView: NSView?

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }

    /// Space / ⌘Y: closes the panel if it's open, cancels a pending download, otherwise shows the files.
    func toggle(_ entries: [FileEntry], deviceID: DeviceID, cache: PreviewCache,
                onError: @escaping @MainActor (MTPError) -> Void) {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        if pendingRequest != nil {
            invalidate()
            return
        }
        show(entries, deviceID: deviceID, cache: cache, onError: onError)
    }

    /// Shows the files (folders are skipped), replacing whatever the panel shows; never closes it.
    func show(_ entries: [FileEntry], deviceID: DeviceID, cache: PreviewCache,
              onError: @escaping @MainActor (MTPError) -> Void) {
        let files = entries.filter { !$0.isFolder }
        guard !files.isEmpty else { return }
        latestRequest += 1
        let request = latestRequest
        pendingRequest = request
        Task {
            var ready: [URL] = []
            for entry in files {
                do {
                    ready.append(try await cache.file(for: entry, deviceID: deviceID))
                } catch {
                    if request == latestRequest {
                        pendingRequest = nil
                        onError(MTPError.from(error))
                    }
                    return
                }
            }
            guard request == latestRequest, let panel = QLPreviewPanel.shared() else { return }
            pendingRequest = nil
            urls = ready
            present(panel)
        }
    }

    /// Drops any pending download so it can't pop up later (folder or device changed, or the user cancelled).
    func invalidate() {
        latestRequest += 1
        pendingRequest = nil
    }

    private func present(_ panel: QLPreviewPanel) {
        if panel.isVisible, panel.currentController != nil {
            panel.reloadData()
            return
        }
        // The panel finds its controller by walking the responder chain from the key window.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           !Self.acceptsControl(window.firstResponder, panel),
           let view = Self.findController(in: window.contentView, panel) {
            window.makeFirstResponder(view)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private static func acceptsControl(_ responder: NSResponder?, _ panel: QLPreviewPanel) -> Bool {
        responder?.acceptsPreviewPanelControl(panel) == true
    }

    private static func findController(in view: NSView?, _ panel: QLPreviewPanel) -> NSView? {
        guard let view else { return nil }
        if view.acceptsPreviewPanelControl(panel) { return view }
        for sub in view.subviews { if let found = findController(in: sub, panel) { return found } }
        return nil
    }

    /// Called from the controlling view's `beginPreviewPanelControl`.
    func attach(_ panel: QLPreviewPanel, from view: NSView) {
        controllingView = view
        panel.dataSource = self
        panel.delegate = self
    }

    /// Called from the controlling view's `endPreviewPanelControl`.
    func detach(_ panel: QLPreviewPanel, from view: NSView) {
        if controllingView === view { controllingView = nil }
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
    }

    /// Once the panel is key it receives Space and arrows; hand them back to the list or grid.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        nonisolated(unsafe) let keyEvent: NSEvent = event // delivered on the main thread
        return MainActor.assumeIsolated {
            guard let view = controllingView else { return false }
            view.keyDown(with: keyEvent)
            return true
        }
    }

    // QLPreviewPanel calls these on the main thread.
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        // NSURL is Sendable; the `any QLPreviewItem` existential isn't, so convert outside the closure.
        let url: NSURL? = MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
        return url
    }
}
