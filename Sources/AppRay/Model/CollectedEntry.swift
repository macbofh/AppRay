import Foundation

/// One row destined for a CSV export — the identifiers an admin passes
/// around a team before building a Blueprint entry or a Denied Software
/// rule from it. Gathered either from a bundle AppRay analysed, which
/// carries code-signing facts, or from an App Store lookup, which only ever
/// carries a Bundle ID.
struct CollectedEntry: Hashable, Sendable, Identifiable {
    enum Source: String, Sendable {
        case localAnalysis = "Local analysis"
        case appStoreLookup = "App Store lookup"
    }

    var id: String { "\(source.rawValue).\(bundleIdentifier ?? name).\(platform)" }
    var name: String
    var bundleIdentifier: String?
    var platform: String
    var developerName: String?
    var teamIdentifier: String?
    var cdHash: String?
    var designatedRequirement: String?
    var source: Source

    static func local(app: AnalyzedApp) -> CollectedEntry {
        CollectedEntry(
            name: app.info.name,
            bundleIdentifier: app.info.bundleIdentifier,
            platform: app.info.platform.label,
            developerName: nil,
            teamIdentifier: app.signature.teamIdentifier,
            cdHash: app.signature.cdHash,
            designatedRequirement: app.signature.designatedRequirement,
            source: .localAnalysis
        )
    }

    static func appStore(result: AppStoreLookupResult) -> CollectedEntry {
        CollectedEntry(
            name: result.name,
            bundleIdentifier: result.bundleIdentifier,
            platform: result.platform.label,
            developerName: result.developerName,
            teamIdentifier: nil,
            cdHash: nil,
            designatedRequirement: nil,
            source: .appStoreLookup
        )
    }
}
