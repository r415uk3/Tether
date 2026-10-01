import Foundation
import CLibMTP
import MTPKit

/// Debounces USB events into rescans and retries locked/claimed phones every 3 seconds.
final class Rescanner: @unchecked Sendable {
    private let service: LocalMTPService
    private var pending: DispatchWorkItem?
    private let retryTimer = DispatchSource.makeTimerSource(queue: .main)

    init(service: LocalMTPService) {
        self.service = service
        retryTimer.schedule(deadline: .now() + 3, repeating: 3)
        retryTimer.setEventHandler { [service] in
            Task { if await service.hasUnavailableDevices { await service.rescan() } }
        }
        retryTimer.resume()
    }

    /// Main queue only.
    func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [service] in Task { await service.rescan() } }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: LocalMTPService
    init(service: LocalMTPService) { self.service = service }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        MTPXPCEndpoint.accept(connection, service: service)
        return true
    }
}

LIBMTP_Init()
let service = LocalMTPService(provider: LibMTPProvider())
let rescanner = Rescanner(service: service)
let usbWatcher = USBWatcher { rescanner.schedule() }
let delegate = ListenerDelegate(service: service)
let listener = NSXPCListener.service()
listener.delegate = delegate
rescanner.schedule()
listener.resume() // never returns
