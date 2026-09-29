import Foundation

/// One row destined for a CSV export — the identifiers an admin passes
/// around a team before building a Blueprint entry or a Denied Software
/// rule from it. Gathered either from a bundle AppRay analysed, which
/// carries every code-signing fact the app exposed, or from an App Store
/// lookup, which only ever carries catalog metadata. Each source fills in
/// its own block of columns and leaves the other's blank — a single shape
/// so the CSV export and the favorites table share one row type.
struct CollectedEntry: Hashable, Sendable, Identifiable {
    enum Source: String, Sendable {
        case localAnalysis = "Local analysis"
        case appStoreLookup = "App Store lookup"
    }

    var id: String { "\(source.rawValue).\(bundleIdentifier ?? name).\(platform)" }
    var name: String
    var bundleIdentifier: String?
    var platform: String
    var version: String?
    var source: Source
    /// `false` only for a local app favorited straight from the sidebar's
    /// quick heart, before it was ever opened — every other field below is
    /// still nil at that point. An App Store lookup has no bundle to
    /// analyze, so it counts as complete for what it is.
    var isFullyAnalyzed: Bool

    /// Where to reopen this app's details from — the bundle on disk for a
    /// local entry, the original lookup for an App Store one.
    var localURL: URL?
    var appStoreResult: AppStoreLookupResult?

    // MARK: - Local analysis

    var path: String?
    var executableName: String?
    var applicationCategory: String?
    var copyright: String?
    var urlSchemes: String?
    var isAgent: String?
    var architectures: String?
    var sdkVersion: String?
    var minimumSystemVersion: String?
    var teamIdentifier: String?
    var signingIdentifier: String?
    var cdHash: String?
    var designatedRequirement: String?
    var ddmComposedIdentifier: String?
    var signingState: String?
    var notarization: String?
    var gatekeeperVerdict: String?
    var hasStapledTicket: String?
    var hasHardenedRuntime: String?
    var isAdHoc: String?
    var certificateAuthority: String?
    var certificateValidity: String?
    var isQuarantined: String?
    var quarantineSource: String?
    var privilegeFindingsCount: String?
    var componentsCount: String?

    // MARK: - App Store

    var developerName: String?
    var price: String?
    var size: String?
    var minimumOSVersion: String?
    var vppLicensing: String?
    var appStorePageURL: String?
    var developerPageURL: String?
    var iconURL: String?
    var sellerPageURL: String?

    static func local(app: AnalyzedApp) -> CollectedEntry {
        CollectedEntry(
            name: app.info.name,
            bundleIdentifier: app.info.bundleIdentifier,
            platform: app.info.platform.label,
            version: app.info.versionSummary,
            source: .localAnalysis,
            isFullyAnalyzed: true,
            localURL: app.info.url,
            path: app.info.url.path,
            executableName: app.info.executableName,
            applicationCategory: app.info.applicationCategory,
            copyright: app.info.copyright,
            urlSchemes: app.info.urlSchemes.isEmpty ? nil : app.info.urlSchemes.joined(separator: ", "),
            isAgent: app.info.isAgent ? "Yes" : "No",
            architectures: app.machO.architectures.isEmpty ? nil : app.machO.architectures.joined(separator: ", "),
            sdkVersion: app.machO.sdkVersion,
            minimumSystemVersion: app.info.minimumSystemVersion ?? app.machO.minimumOSVersion,
            teamIdentifier: app.signature.teamIdentifier,
            signingIdentifier: app.signature.signingIdentifier,
            cdHash: app.signature.cdHash,
            designatedRequirement: app.signature.designatedRequirement,
            ddmComposedIdentifier: app.ddmComposedIdentifier,
            signingState: app.signingState.rawValue,
            notarization: app.trust?.gatekeeper.notarization.label,
            gatekeeperVerdict: app.trust.map { describe($0.gatekeeper.verdict) },
            hasStapledTicket: app.trust.map { $0.gatekeeper.hasStapledTicket ? "Yes" : "No" },
            hasHardenedRuntime: app.signature.hasHardenedRuntime ? "Yes" : "No",
            isAdHoc: app.signature.isAdHoc ? "Yes" : "No",
            certificateAuthority: app.signature.authority,
            certificateValidity: app.signature.leafCertificate?.validity.summary,
            isQuarantined: app.quarantine != nil ? "Yes" : "No",
            quarantineSource: app.quarantine?.agentName,
            privilegeFindingsCount: String(app.findings.count),
            componentsCount: String(app.components.count)
        )
    }

    /// From the fast, unanalysed listing of an installed app — favoriting
    /// from the sidebar does not wait for a full analysis. Carries no
    /// code-signing facts, only what the scanner already read.
    static func local(summary: LocalApplicationSummary) -> CollectedEntry {
        CollectedEntry(
            name: summary.name,
            bundleIdentifier: summary.bundleIdentifier,
            platform: BundlePlatform.macOS.label,
            version: nil,
            source: .localAnalysis,
            isFullyAnalyzed: false,
            localURL: summary.url,
            path: summary.url.path
        )
    }

    static func appStore(result: AppStoreLookupResult) -> CollectedEntry {
        CollectedEntry(
            name: result.name,
            bundleIdentifier: result.bundleIdentifier,
            platform: result.platform.label,
            version: result.version,
            source: .appStoreLookup,
            isFullyAnalyzed: true,
            appStoreResult: result,
            developerName: result.sellerName ?? result.developerName,
            price: price(for: result),
            size: result.formattedFileSize,
            minimumOSVersion: result.minimumOSVersion,
            vppLicensing: result.isVppDeviceBasedLicensingEnabled.map { $0 ? "Enabled" : "Not enabled" },
            appStorePageURL: result.appStoreURL?.absoluteString,
            developerPageURL: result.developerViewURL?.absoluteString,
            iconURL: result.largestArtworkURL?.absoluteString,
            sellerPageURL: result.sellerURL?.absoluteString
        )
    }

    private static func price(for result: AppStoreLookupResult) -> String? {
        if let formattedPrice = result.formattedPrice, !formattedPrice.isEmpty { return formattedPrice }
        guard let price = result.price else { return nil }
        return price == 0 ? "Free" : "\(price) \(result.currency ?? "")"
    }

    private static func describe(_ verdict: GatekeeperVerdict) -> String {
        switch verdict {
        case .accepted(let source): "Accepted (\(source))"
        case .rejected(let reason): "Rejected (\(reason))"
        case .unknown(let detail): "Unknown (\(detail))"
        }
    }
}
