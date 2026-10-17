/// One USB interface descriptor of a connected device.
public struct USBInterfaceInfo: Sendable, Equatable {
    public let interfaceClass: Int
    public let subclass: Int
    public let protocolCode: Int
    public let name: String?

    public init(_ interfaceClass: Int, _ subclass: Int, _ protocolCode: Int, name: String?) {
        self.interfaceClass = interfaceClass
        self.subclass = subclass
        self.protocolCode = protocolCode
        self.name = name
    }
}

/// Decides whether a USB device is a phone in File transfer (MTP) mode.
public enum FileTransferMatch {
    /// True when some interface has class 6 (still image) or 255 (vendor) and a name containing "MTP".
    public static func isFileTransfer(_ interfaces: [USBInterfaceInfo]) -> Bool {
        interfaces.contains { info in
            (info.interfaceClass == 6 || info.interfaceClass == 255)
                && (info.name?.lowercased().contains("mtp") ?? false)
        }
    }
}
