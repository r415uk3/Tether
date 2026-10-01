import Foundation
import IOKit
import IOKit.usb

/// Calls `onChange` on the main queue whenever any USB device appears or disappears.
final class USBWatcher: @unchecked Sendable {
    private let onChange: @MainActor () -> Void
    private var port: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            let watcher = Unmanaged<USBWatcher>.fromOpaque(context).takeUnretainedValue()
            USBWatcher.drain(iterator)
            MainActor.assumeIsolated { watcher.onChange() } // notifications are delivered on .main
        }
        _ = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"),
                                             callback, context, &addedIterator)
        Self.drain(addedIterator) // arms the notification
        _ = IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"),
                                             callback, context, &removedIterator)
        Self.drain(removedIterator)
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let object = IOIteratorNext(iterator), object != 0 {
            IOObjectRelease(object)
        }
    }
}
