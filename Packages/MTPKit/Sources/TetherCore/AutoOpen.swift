import Foundation
import Observation

public enum LoginItemStatus: Sendable { case notRegistered, enabled, requiresApproval, notFound }

/// The launcher login item, as seen by the app. The real implementation wraps `SMAppService`.
@MainActor public protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// Turns the auto-open launcher on and off, and re-registers it after app updates.
///
/// After an update with a new ad-hoc signature, the login item still reports `.enabled` but launchd refuses to
/// spawn the helper. Unregistering, waiting for the old helper to exit, then registering again fixes it;
/// registering again immediately does not.
@MainActor
@Observable
public final class AutoOpenController {
    public enum State: Equatable, Sendable { case off, on, needsApproval }

    public private(set) var state: State = .off
    /// `localizedDescription` of the last failed register or unregister; cleared by the next success.
    public private(set) var lastError: String?

    @ObservationIgnored private let service: any LoginItemService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let isHelperRunning: @MainActor () -> Bool
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let pollTimeout: Duration
    @ObservationIgnored private let settleDelay: Duration
    /// Bumped by every `setEnabled`, so a repair in flight knows the user changed the setting meanwhile.
    @ObservationIgnored private var userChanges = 0
    @ObservationIgnored private var launchRepair: Task<Void, Never>?

    public init(service: any LoginItemService,
                defaults: UserDefaults = .standard,
                currentVersion: String,
                isHelperRunning: @escaping @MainActor () -> Bool,
                pollInterval: Duration = .milliseconds(250),
                pollTimeout: Duration = .seconds(5),
                settleDelay: Duration = .seconds(1)) {
        self.service = service
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.isHelperRunning = isHelperRunning
        self.pollInterval = pollInterval
        self.pollTimeout = pollTimeout
        self.settleDelay = settleDelay
        refresh()
    }

    public var isOn: Bool { state == .on }

    /// Re-reads the service status; the user can change it in System Settings at any time.
    public func refresh() {
        switch service.status {
        case .enabled: state = .on
        case .requiresApproval: state = .needsApproval
        case .notRegistered, .notFound: state = .off
        }
    }

    public func setEnabled(_ on: Bool) async {
        userChanges += 1
        if on {
            register()
        } else {
            do {
                try service.unregister()
                defaults.removeObject(forKey: SettingsKey.autoOpenRegisteredVersion)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
            refresh()
        }
    }

    /// Starts `repairIfNeeded` the first time it is called and returns that same task on every later call,
    /// so the repair runs once per launch no matter how often a window appears.
    @discardableResult
    public func repairOncePerLaunch() -> Task<Void, Never> {
        if let launchRepair { return launchRepair }
        let task = Task { await repairIfNeeded() }
        launchRepair = task
        return task
    }

    /// Re-registers a launcher that is on but stale: registered by another version, or not running.
    ///
    /// Once it has unregistered, it always waits for the old helper and the settle delay, even if the calling task
    /// is cancelled: registering right away leaves the launcher unable to start. If the user turns the setting
    /// on or off in the meantime, their choice stands and the repair does not register.
    public func repairIfNeeded() async {
        guard service.status == .enabled else { return }
        let storedVersion = defaults.string(forKey: SettingsKey.autoOpenRegisteredVersion)
        guard storedVersion != currentVersion || !isHelperRunning() else { return }
        let changesAtStart = userChanges
        do {
            try service.unregister()
        } catch {
            lastError = error.localizedDescription
            refresh()
            return
        }
        // An unstructured task does not inherit cancellation, so its sleeps really wait.
        await Task { await self.waitForHelperToExitAndSettle() }.value
        guard userChanges == changesAtStart else { return }
        register()
    }

    private func register() {
        do {
            try service.register()
            defaults.set(currentVersion, forKey: SettingsKey.autoOpenRegisteredVersion)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Polls until the old helper process is gone or `pollTimeout` passes, then waits `settleDelay`.
    private func waitForHelperToExitAndSettle() async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: pollTimeout)
        while isHelperRunning(), clock.now < deadline {
            try? await Task.sleep(for: pollInterval)
        }
        try? await Task.sleep(for: settleDelay)
    }
}
