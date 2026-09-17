import Foundation

/// Builds a `com.apple.configuration.app.settings` declaration carrying
/// `Privacy.PermissionDefaults` for one app.
///
/// Schema: `Reference/com.apple.configuration.app.settings.yaml`.
enum DDMDeclarationBuilder {
    static let declarationType = "com.apple.configuration.app.settings"

    /// The key a `PermissionDefaults` dictionary expects on macOS: the bundle
    /// ID, a space, then the designated requirement wrapped in braces.
    ///
    /// Apple's example is `com.example.app {anchor apple generic}`. The
    /// requirement string is inserted verbatim, quotes and all — it is not
    /// escaped, because the format is brace-delimited, not quoted.
    static func composedIdentifier(bundleIdentifier: String, designatedRequirement: String) -> String {
        "\(bundleIdentifier) {\(designatedRequirement)}"
    }

    static func build(app: AnalyzedApp, plan: ExportPlan) throws -> Data {
        let declaration = try declarationDictionary(app: app, plan: plan)
        return try JSONSerialization.data(
            withJSONObject: declaration,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func preview(app: AnalyzedApp, plan: ExportPlan) -> String {
        do {
            return String(decoding: try build(app: app, plan: plan), as: UTF8.self)
        } catch {
            return "// \(error.localizedDescription)"
        }
    }

    private static func declarationDictionary(
        app: AnalyzedApp,
        plan: ExportPlan
    ) throws -> [String: Any] {
        guard let bundleIdentifier = app.info.bundleIdentifier else {
            throw ExportError.missingBundleIdentifier
        }
        guard let requirement = app.signature.designatedRequirement else {
            throw ExportError.missingDesignatedRequirement
        }

        let included = plan.decisions(representableIn: .ddm)
        guard !included.isEmpty else { throw ExportError.nothingToExport(.ddm) }

        // OrganizationJustification is required, and the device shows it to the
        // user in the consent prompt.
        var permissions: [String: Any] = [
            "OrganizationJustification": plan.organizationJustification,
        ]
        for decision in included {
            guard let key = decision.service.ddmPrivacyKey else { continue }
            permissions[key] = decision.service == .location
                ? decision.locationMode
                : "Allow"
        }

        let identifier = composedIdentifier(
            bundleIdentifier: bundleIdentifier,
            designatedRequirement: requirement
        )

        return [
            "Type": declarationType,
            "Identifier": plan.declarationIdentifier.uuidString,
            "ServerToken": plan.serverToken.uuidString,
            "Payload": [
                "Privacy": [
                    "PermissionDefaults": [identifier: permissions],
                ],
            ],
        ]
    }
}
