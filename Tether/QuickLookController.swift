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

    /// Shows the selected files (folders are skipped), or closes the panel if it's open.
    func toggle(_ entries: [FileEntry], deviceID: DeviceID, cache: PreviewCache,
                onError: @escaping @MainActor (MTPError) -> Void) {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        let files = entries.filter { !$0.isFolder }
        guard !files.isEmpty else { return }
        latestRequest += 1
        let request = latestRequest
        Task {
            var ready: [URL] = []
            for entry in files {
                do {
                    ready.append(try await cache.file(for: entry, deviceID: deviceID))
                } catch {
                    if request == latestRequest { onError(MTPError.from(error)) }
                    return
                }
            }
            guard request == latestRequest, let panel = QLPreviewPanel.shared() else { return }
            urls = ready
            attach(panel)
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func attach(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func detach(_ panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
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
