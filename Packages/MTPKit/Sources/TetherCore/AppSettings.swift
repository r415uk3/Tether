import Foundation

public enum SettingsKey {
    public static let downloadFolderPath = "downloadFolderPath"
    public static let conflictDefault = "conflictDefault"
    public static let showHiddenFiles = "showHiddenFiles"
    public static let viewMode = "viewMode"
}

/// The Settings choice for name clashes; `.ask` shows the dialog.
public enum ConflictDefault: String, CaseIterable, Sendable {
    case ask, replace, keepBoth, skip

    public var choice: ConflictChoice? {
        switch self {
        case .ask: nil
        case .replace: .replace
        case .keepBoth: .keepBoth
        case .skip: .skip
        }
    }

    public var title: String {
        switch self {
        case .ask: String(localized: "Ask Every Time", bundle: .module)
        case .replace: String(localized: "Replace", bundle: .module)
        case .keepBoth: String(localized: "Keep Both", bundle: .module)
        case .skip: String(localized: "Skip", bundle: .module)
        }
    }
}

public enum AppSettings {
    public static var defaultDownloadFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// The Settings download folder if it still exists as a directory, otherwise ~/Downloads.
    public static func downloadFolder(in defaults: UserDefaults = .standard) -> URL {
        guard let path = defaults.string(forKey: SettingsKey.downloadFolderPath), !path.isEmpty else {
            return defaultDownloadFolder
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return defaultDownloadFolder
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public static func conflictDefault(in defaults: UserDefaults = .standard) -> ConflictDefault {
        defaults.string(forKey: SettingsKey.conflictDefault).flatMap(ConflictDefault.init(rawValue:)) ?? .ask
    }
}

public enum BrowserViewMode: String, CaseIterable, Sendable {
    case icons, list
}
