import Foundation

public final class FakeDeviceProvider: DeviceProvider, @unchecked Sendable {
    private enum Slot {
        case device(FakeDevice)
        case unavailable(AttachedDevice, MTPError)

        var attached: AttachedDevice {
            switch self {
            case .device(let d): AttachedDevice(id: d.info.id, manufacturer: d.info.manufacturer, model: d.info.model)
            case .unavailable(let a, _): a
            }
        }
    }

    private let lock = NSLock()
    private var slots: [DeviceID: Slot] = [:]
    private var opens: [DeviceID: Int] = [:]

    public init() {}

    /// Attaches (or replaces) a working device.
    public func attach(_ device: FakeDevice) { lock.withLock { slots[device.info.id] = .device(device) } }

    /// Attaches a device whose `open` fails with `error` (e.g. a locked phone).
    public func attachUnavailable(_ device: AttachedDevice, error: MTPError) {
        lock.withLock { slots[device.id] = .unavailable(device, error) }
    }

    public func detach(_ id: DeviceID) { lock.withLock { slots[id] = nil } }
    public func openCount(_ id: DeviceID) -> Int { lock.withLock { opens[id, default: 0] } }

    public func attachedDevices() -> [AttachedDevice] {
        lock.withLock { slots.values.map(\.attached).sorted { $0.id < $1.id } }
    }

    public func open(_ device: AttachedDevice) throws -> any MTPDevice {
        try lock.withLock {
            opens[device.id, default: 0] += 1
            switch slots[device.id] {
            case .device(let d): return d
            case .unavailable(_, let error): throw error
            case nil: throw MTPError.deviceDisconnected
            }
        }
    }

    /// Two demo phones: a working Pixel with sample folders and a locked Galaxy.
    public static func demo() -> FakeDeviceProvider {
        let provider = FakeDeviceProvider()
        let pixel = FakeDevice(id: "demo-pixel", manufacturer: "Google", model: "Pixel 9",
                               chunkSize: 256 * 1024, chunkDelay: 0.05)
        let dcim = pixel.addFolder("DCIM")
        let camera = pixel.addFolder("Camera", in: dcim.objectID)
        for i in 1...12 {
            pixel.addFile(String(format: "IMG_%04d.jpg", i), data: Data(count: 2_000_000), in: camera.objectID)
        }
        pixel.addFolder("Download")
        pixel.addFolder("Music")
        pixel.addFile("notes.txt", data: Data("Hello from Tether".utf8))
        provider.attach(pixel)
        provider.attachUnavailable(AttachedDevice(id: "demo-galaxy", manufacturer: "Samsung", model: "Galaxy S25"),
                                   error: .deviceLocked)
        return provider
    }
}
