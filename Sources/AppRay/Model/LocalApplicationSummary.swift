import Foundation

/// A fast, name-and-identifier-only listing of one installed application —
/// enough to make the drop target searchable, without running the full
/// analysis until the admin actually picks it.
struct LocalApplicationSummary: Hashable, Sendable, Identifiable {
    var id: URL { url }
    var url: URL
    var name: String
    var bundleIdentifier: String?
}
