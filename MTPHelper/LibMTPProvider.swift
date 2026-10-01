import Foundation
import CLibMTP
import MTPKit

final class LibMTPProvider: DeviceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var raw: [DeviceID: LIBMTP_raw_device_t] = [:]

    func attachedDevices() -> [AttachedDevice] {
        var list: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        guard LIBMTP_Detect_Raw_Devices(&list, &count) == LIBMTP_ERROR_NONE, let list else {
            lock.withLock { raw.removeAll() }
            return []
        }
        defer { free(list) }
        var found: [DeviceID: LIBMTP_raw_device_t] = [:]
        var devices: [AttachedDevice] = []
        for i in 0..<Int(count) {
            let r = list[i]
            let id = "\(String(r.bus_location, radix: 16))-\(r.devnum)"
            found[id] = r
            devices.append(AttachedDevice(id: id,
                                          manufacturer: r.device_entry.vendor.map { String(cString: $0) } ?? "",
                                          model: r.device_entry.product.map { String(cString: $0) } ?? "Android"))
        }
        lock.withLock { raw = found }
        return devices
    }

    func open(_ device: AttachedDevice) throws -> any MTPDevice {
        guard var r = lock.withLock({ raw[device.id] }) else { throw MTPError.deviceDisconnected }
        guard let handle = LIBMTP_Open_Raw_Device_Uncached(&r) else {
            // On macOS this almost always means ptpcamerad (Image Capture) holds the interface.
            throw MTPError.claimedByOtherProcess
        }
        let opened = LibMTPDevice(handle: handle, attached: device)
        // A locked Android phone opens but exposes no storage until unlocked.
        if (try? opened.storages())?.isEmpty ?? true {
            opened.close()
            throw MTPError.deviceLocked
        }
        return opened
    }
}
