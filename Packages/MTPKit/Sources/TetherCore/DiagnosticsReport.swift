import Foundation
import MTPKit

/// Plain-text report for bug reports. Contains no file names, folder names or serials.
public enum DiagnosticsReport {
    public static func make(appVersion: String, macOSVersion: String, devices: [DeviceInfo],
                            appLog: [String], helperLog: [String]?) -> String {
        var out = ["Tether \(appVersion)", "macOS \(macOSVersion)", "", "Phones:"]
        if devices.isEmpty {
            out.append("  No phones connected")
        }
        for device in devices {
            let state: String = switch device.state {
            case .ready: "ready"
            case .unavailable(let error): "unavailable: \(error.logDescription)"
            }
            out.append("  \(device.manufacturer) \(device.model) — Android \(device.osVersion ?? "?") — \(state)")
        }
        out += ["", "App log:"] + (appLog.isEmpty ? ["  (empty)"] : appLog.map { "  \($0)" })
        out += ["", "Helper log:"]
        if let helperLog {
            out += helperLog.isEmpty ? ["  (empty)"] : helperLog.map { "  \($0)" }
        } else {
            out.append("  Helper log unavailable")
        }
        return out.joined(separator: "\n")
    }
}
