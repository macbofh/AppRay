import Foundation

/// Turns a collected list into CSV text — the format admins pass around a
/// team before building a Blueprint entry or a profile from it. Local
/// analysis and App Store lookups fill in different blocks of columns; a row
/// from the other source simply leaves its block blank.
enum CSVExportBuilder {
    private static let header = [
        "Name", "Bundle Identifier", "Platform", "Version", "Source",
        // Local analysis
        "Path", "Executable", "Application Category", "Copyright", "URL Schemes",
        "Agent (No Dock Icon)", "Architectures", "Built Against SDK", "Minimum System Version",
        "Team Identifier", "Signing Identifier", "CD Hash", "Designated Requirement",
        "DDM Composed Identifier", "Signing State", "Notarization", "Gatekeeper Verdict",
        "Stapled Ticket", "Hardened Runtime", "Ad-hoc Signed", "Certificate Authority",
        "Certificate Validity", "Quarantined", "Quarantine Source", "Privilege Findings Count",
        "Components Count",
        // App Store
        "Developer", "Price", "Size", "Minimum OS", "VPP Device-based Licensing",
        "App Store Page", "Developer Page", "Icon URL", "Seller Page",
    ]

    static func build(entries: [CollectedEntry]) -> String {
        var lines = [header.map(escape).joined(separator: ",")]
        for entry in entries {
            let fields = [
                entry.name,
                entry.bundleIdentifier ?? "",
                entry.platform,
                entry.version ?? "",
                entry.source.rawValue,
                entry.path ?? "",
                entry.executableName ?? "",
                entry.applicationCategory ?? "",
                entry.copyright ?? "",
                entry.urlSchemes ?? "",
                entry.isAgent ?? "",
                entry.architectures ?? "",
                entry.sdkVersion ?? "",
                entry.minimumSystemVersion ?? "",
                entry.teamIdentifier ?? "",
                entry.signingIdentifier ?? "",
                entry.cdHash ?? "",
                entry.designatedRequirement ?? "",
                entry.ddmComposedIdentifier ?? "",
                entry.signingState ?? "",
                entry.notarization ?? "",
                entry.gatekeeperVerdict ?? "",
                entry.hasStapledTicket ?? "",
                entry.hasHardenedRuntime ?? "",
                entry.isAdHoc ?? "",
                entry.certificateAuthority ?? "",
                entry.certificateValidity ?? "",
                entry.isQuarantined ?? "",
                entry.quarantineSource ?? "",
                entry.privilegeFindingsCount ?? "",
                entry.componentsCount ?? "",
                entry.developerName ?? "",
                entry.price ?? "",
                entry.size ?? "",
                entry.minimumOSVersion ?? "",
                entry.vppLicensing ?? "",
                entry.appStorePageURL ?? "",
                entry.developerPageURL ?? "",
                entry.iconURL ?? "",
                entry.sellerPageURL ?? "",
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
            return field
        }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
