import AppKit
import Foundation
import IOKit
import IOKit.usb
import os
import PhoneDetection

/// Watches USB device arrivals and calls `onFileTransferArrival` when a phone in File transfer mode is plugged in.
/// Only reads IORegistry properties: it never opens a device or creates a user client.
@MainActor
final class USBArrivalWatcher {
    /// Interfaces appeared ~1.5 s after the device notification on a real phone; retry once if they haven't yet.
    private static let firstReadDelay: Duration = .milliseconds(1500)
    private static let secondReadDelay: Duration = .milliseconds(1500) // total 3 s after arrival

    private let onFileTransferArrival: @MainActor () -> Void
    private let logger = Logger(subsystem: "dev.tether.Tether.Launcher", category: "usb")
    private var filter = ArrivalFilter()
    private var port: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    /// Arrivals waiting for their delayed interface read; removal cancels them.
    private var pending: Set<UInt64> = []
    private var wakeObserver: NSObjectProtocol?

    init(onFileTransferArrival: @escaping @MainActor () -> Void) {
        self.onFileTransferArrival = onFileTransferArrival
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()

        let added: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            MainActor.assumeIsolated { // notifications are delivered on .main
                Unmanaged<USBArrivalWatcher>.fromOpaque(context).takeUnretainedValue().handleArrivals(iterator)
            }
        }
        let removed: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<USBArrivalWatcher>.fromOpaque(context).takeUnretainedValue().handleRemovals(iterator)
            }
        }
        let addedResult = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
                                                           IOServiceMatching("IOUSBHostDevice"), added, context,
                                                           &addedIterator)
        if addedResult != KERN_SUCCESS {
            logger.error("Can't watch USB arrivals: IOServiceAddMatchingNotification returned \(addedResult)")
        }
        noteExistingDevices() // drains and arms the "added" notification
        let removedResult = IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                                                             IOServiceMatching("IOUSBHostDevice"), removed, context,
                                                             &removedIterator)
        if removedResult != KERN_SUCCESS {
            logger.error("Can't watch USB removals: IOServiceAddMatchingNotification returned \(removedResult)")
        }
        handleRemovals(removedIterator) // arms the "terminated" notification

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.filter.noteWake(at: Date()) }
        }
    }

    // MARK: - Notifications

    private func noteExistingDevices() {
        while case let device = IOIteratorNext(addedIterator), device != 0 {
            let interfaces = Self.interfaces(of: device)
            filter.noteExisting(entryID: Self.entryID(of: device), key: Self.key(of: device),
                                isFileTransfer: FileTransferMatch.isFileTransfer(interfaces))
            IOObjectRelease(device)
        }
    }

    private func handleArrivals(_ iterator: io_iterator_t) {
        while case let device = IOIteratorNext(iterator), device != 0 {
            // Keep the reference from IOIteratorNext until the delayed read is done; released in `finishArrival`.
            pending.insert(Self.entryID(of: device))
            let arrivedAt = Date() // the filter's grace windows count from the notification, not the delayed read
            Task { [self] in
                try? await Task.sleep(for: Self.firstReadDelay)
                var interfaces = Self.interfaces(of: device)
                if interfaces.isEmpty, pending.contains(Self.entryID(of: device)) {
                    try? await Task.sleep(for: Self.secondReadDelay)
                    interfaces = Self.interfaces(of: device)
                }
                finishArrival(device, interfaces: interfaces, arrivedAt: arrivedAt)
            }
        }
    }

    private func finishArrival(_ device: io_object_t, interfaces: [USBInterfaceInfo], arrivedAt: Date) {
        defer { IOObjectRelease(device) }
        let entryID = Self.entryID(of: device)
        let name = Self.string(device, "kUSBProductString") ?? "unknown device"
        guard pending.remove(entryID) != nil else {
            logger.info("\(name, privacy: .public) left before its interfaces were read; ignored")
            return
        }
        let isFileTransfer = FileTransferMatch.isFileTransfer(interfaces)
        let shouldOpen = filter.noteArrival(entryID: entryID, key: Self.key(of: device),
                                            isFileTransfer: isFileTransfer, at: arrivedAt)
        let outcome = shouldOpen ? "opening Tether"
            : isFileTransfer ? "not opening (wake, reconnect or duplicate)"
            : "not opening (not in File transfer mode)"
        logger.info("""
            Arrival: \(name, privacy: .public), \(interfaces.count) interfaces, \
            isFileTransfer=\(isFileTransfer), \(outcome, privacy: .public)
            """)
        if shouldOpen { onFileTransferArrival() }
    }

    private func handleRemovals(_ iterator: io_iterator_t) {
        while case let device = IOIteratorNext(iterator), device != 0 {
            let entryID = Self.entryID(of: device)
            pending.remove(entryID)
            filter.noteRemoval(entryID: entryID, at: Date())
            IOObjectRelease(device)
        }
    }

    // MARK: - IORegistry reads

    private static func entryID(of entry: io_registry_entry_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        return id
    }

    /// Identifies the same phone across re-enumerations: its serial, or its port when it has none.
    private static func key(of device: io_registry_entry_t) -> String {
        for serialKey in ["kUSBSerialNumberString", "USB Serial Number"] {
            if let serial = string(device, serialKey), !serial.isEmpty { return serial }
        }
        return "loc:\(int(device, "locationID") ?? 0)"
    }

    private static func interfaces(of device: io_registry_entry_t) -> [USBInterfaceInfo] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(device, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [USBInterfaceInfo] = []
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            guard IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
                  let interfaceClass = int(child, "bInterfaceClass"),
                  let subclass = int(child, "bInterfaceSubClass"),
                  let protocolCode = int(child, "bInterfaceProtocol") else { continue }
            result.append(USBInterfaceInfo(interfaceClass, subclass, protocolCode, name: string(child, "kUSBString")))
        }
        return result
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func int(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        (property(entry, key) as? NSNumber)?.intValue
    }

    private static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
        property(entry, key) as? String
    }
}
