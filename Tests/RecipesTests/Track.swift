/// An app's own queue entry. `Player` takes any `Hashable & Sendable`.
struct Track: Hashable, Sendable {
    var id: Int
}
