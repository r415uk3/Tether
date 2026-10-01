import AppKit
import UniformTypeIdentifiers
import MTPKit
import TetherCore

/// Lets Finder pull a phone file: the download is queued when the user drops.
final class FilePromise: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let entry: FileEntry
    private let deviceID: DeviceID
    private let queue: TransferQueue

    private init(entry: FileEntry, deviceID: DeviceID, queue: TransferQueue) {
        self.entry = entry
        self.deviceID = deviceID
        self.queue = queue
    }

    @MainActor
    static func provider(for entry: FileEntry, deviceID: DeviceID, queue: TransferQueue) -> NSFilePromiseProvider {
        let type: UTType = entry.isFolder
            ? .folder
            : UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
        let delegate = FilePromise(entry: entry, deviceID: deviceID, queue: queue)
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: delegate)
        provider.userInfo = delegate // the provider holds its delegate weakly
        return provider
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        Transfers.safeName(entry.name)
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let directory = url.deletingLastPathComponent()
        let completion = Unchecked(completionHandler)
        let entry = entry, deviceID = deviceID, queue = queue
        Task { @MainActor in
            queue.enqueueDownload(entry, deviceID: deviceID, into: directory) { result in
                switch result {
                case .success: completion.value(nil)
                case .failure(let error): completion.value(error)
                }
            }
        }
    }
}
