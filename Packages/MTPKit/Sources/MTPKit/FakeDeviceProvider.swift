import Foundation

public final class FakeDeviceProvider: DeviceProvider, @unchecked Sendable {
    private enum Slot {
        case device(FakeDevice)
        case unavailable(AttachedDevice, MTPError)
        case claimed(FakeDevice, releasable: Bool)

        func attached(as key: DeviceID) -> AttachedDevice {
            switch self {
            case .device(let d), .claimed(let d, _):
                AttachedDevice(id: key, manufacturer: d.info.manufacturer, model: d.info.model)
            case .unavailable(let a, _): a
            }
        }
    }

    private let lock = NSLock()
    private var slots: [DeviceID: Slot] = [:]
    private var opens: [DeviceID: Int] = [:]
    private var heldOpens: [DeviceID: Int] = [:]
    private var gates: [DeviceID: [DispatchSemaphore]] = [:]
    private var releases = 0

    public init() {}

    /// Attaches (or replaces) a working device under its own ID as transport key.
    public func attach(_ device: FakeDevice) { attach(device, as: device.info.id) }

    /// Attaches (or replaces) a working device under an explicit USB transport key (simulates a replug).
    public func attach(_ device: FakeDevice, as key: DeviceID) { lock.withLock { slots[key] = .device(device) } }

    /// Attaches a device whose `open` fails with `error` (e.g. a locked phone).
    public func attachUnavailable(_ device: AttachedDevice, error: MTPError) {
        lock.withLock { slots[device.id] = .unavailable(device, error) }
    }

    /// Attaches a device that another app holds until `releaseClaims()` (if `releasable`).
    public func attachClaimed(_ device: FakeDevice, as key: DeviceID? = nil, releasable: Bool = true) {
        lock.withLock { slots[key ?? device.info.id] = .claimed(device, releasable: releasable) }
    }

    public var releaseClaimsCalls: Int { lock.withLock { releases } }

    public func releaseClaims() -> Bool {
        lock.withLock {
            releases += 1
            var released = false
            for (key, slot) in slots {
                if case .claimed(let device, true) = slot {
                    slots[key] = .device(device)
                    released = true
                }
            }
            // A non-releasable claim still "signals" the agent but the phone stays held.
            return released || slots.values.contains { if case .claimed = $0 { true } else { false } }
        }
    }

    public func detach(_ id: DeviceID) { lock.withLock { slots[id] = nil } }
    public func openCount(_ id: DeviceID) -> Int { lock.withLock { opens[id, default: 0] } }

    public func attachedDevices() -> [AttachedDevice] {
        lock.withLock { slots.map { key, slot in slot.attached(as: key) }.sorted { $0.id < $1.id } }
    }

    /// Test seam: the next `count` opens of `id` block (outside the lock) until `releaseOpens(id)`.
    /// The open's outcome is decided when it starts, before blocking.
    public func holdOpens(_ id: DeviceID, count: Int = 1) { lock.withLock { heldOpens[id] = count } }

    /// Unblocks every open currently held for `id` and stops holding further opens.
    public func releaseOpens(_ id: DeviceID) {
        let waiting = lock.withLock { () -> [DispatchSemaphore] in
            heldOpens[id] = nil
            return gates.removeValue(forKey: id) ?? []
        }
        waiting.forEach { $0.signal() }
    }

    public func open(_ device: AttachedDevice) throws -> any MTPDevice {
        let (outcome, gate) = lock.withLock { () -> (Result<any MTPDevice, MTPError>, DispatchSemaphore?) in
            opens[device.id, default: 0] += 1
            var gate: DispatchSemaphore?
            if let remaining = heldOpens[device.id], remaining > 0 {
                heldOpens[device.id] = remaining - 1
                gate = DispatchSemaphore(value: 0)
                gates[device.id, default: []].append(gate!)
            }
            switch slots[device.id] {
            case .device(let d): return (.success(d), gate)
            case .unavailable(_, let error): return (.failure(error), gate)
            case .claimed: return (.failure(.claimedByOtherProcess), gate)
            case nil: return (.failure(.deviceDisconnected), gate)
            }
        }
        gate?.wait()
        return try outcome.get()
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
