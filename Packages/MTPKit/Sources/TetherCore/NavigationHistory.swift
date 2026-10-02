/// Finder-style Back/Forward: visiting a new location clears Forward.
public struct NavigationHistory<Location: Equatable & Sendable>: Sendable {
    public private(set) var current: Location
    private var back: [Location] = []
    private var forward: [Location] = []

    public init(start: Location) { current = start }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    public mutating func visit(_ location: Location) {
        guard location != current else { return }
        back.append(current)
        current = location
        forward.removeAll()
    }

    public mutating func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(current)
        current = previous
    }

    public mutating func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(current)
        current = next
    }

    /// Forgets all history (used when the phone reconnects: old folder handles are meaningless).
    public mutating func reset(to location: Location) {
        current = location
        back.removeAll()
        forward.removeAll()
    }
}
