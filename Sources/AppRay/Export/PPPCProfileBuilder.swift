import Foundation

enum ExportError: LocalizedError {
    case nothingToExport(ExportChannel)
    case missingBundleIdentifier
    case missingDesignatedRequirement

    var errorDescription: String? {
        switch self {
        case .nothingToExport(let channel):
            "Nothing to put in the \(channel.title.lowercased())."
        case .missingBundleIdentifier:
            "The app has no CFBundleIdentifier."
        case .missingDesignatedRequirement:
            "The app has no readable designated requirement."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .nothingToExport(.pppc):
            "Select at least one service that a PPPC profile can express."
        case .nothingToExport(.ddm):
            "Select at least one service that has a DDM privacy key and is set to Allow."
        case .missingBundleIdentifier, .missingDesignatedRequirement:
            "Both come from the app bundle. An unsigned or malformed app cannot be targeted by identity."
        }
    }
}

/// Builds a `.mobileconfig` containing a single
/// `com.apple.TCC.configuration-profile-policy` payload.
enum PPPCProfileBuilder {
    static func build(app: AnalyzedApp, plan: ExportPlan) throws -> Data {
        let dictionary = try profileDictionary(app: app, plan: plan)
        return try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
    }

    static func preview(app: AnalyzedApp, plan: ExportPlan) -> String {
        do {
            return String(decoding: try build(app: app, plan: plan), as: UTF8.self)
        } catch {
            return "// \(error.localizedDescription)"
        }
    }

    private static func profileDictionary(app: AnalyzedApp, plan: ExportPlan) throws -> [String: Any] {
        guard let bundleIdentifier = app.info.bundleIdentifier else {
            throw ExportError.missingBundleIdentifier
        }
        guard let requirement = app.signature.designatedRequirement else {
            throw ExportError.missingDesignatedRequirement
        }

        let included = plan.decisions(representableIn: .pppc)
        guard !included.isEmpty else { throw ExportError.nothingToExport(.pppc) }

        var services: [String: [[String: Any]]] = [:]
        for decision in included {
            guard let key = decision.service.pppcServiceKey else { continue }
            guard let entry = entry(
                for: decision,
                bundleIdentifier: bundleIdentifier,
                requirement: requirement,
                plan: plan
            ) else { continue }
            services[key, default: []].append(entry)
        }
        guard !services.isEmpty else { throw ExportError.nothingToExport(.pppc) }

        let payload: [String: Any] = [
            "PayloadType": "com.apple.TCC.configuration-profile-policy",
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(plan.payloadIdentifierPrefix).\(bundleIdentifier).tcc",
            "PayloadUUID": plan.payloadUUID.uuidString,
            "PayloadDisplayName": "Privacy Preferences Policy Control",
            "PayloadOrganization": plan.organization,
            "Services": services,
        ]

        return [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(plan.payloadIdentifierPrefix).\(bundleIdentifier)",
            "PayloadUUID": plan.profileUUID.uuidString,
            "PayloadDisplayName": plan.displayName,
            "PayloadDescription": plan.descriptionText,
            "PayloadOrganization": plan.organization,
            // PPPC is a device-wide policy and has to be delivered system-wide.
            "PayloadScope": "System",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [payload],
        ]
    }

    private static func entry(
        for decision: ServiceDecision,
        bundleIdentifier: String,
        requirement: String,
        plan: ExportPlan
    ) -> [String: Any]? {
        var entry: [String: Any] = [
            "Identifier": bundleIdentifier,
            "IdentifierType": "bundleID",
            "CodeRequirement": requirement,
            // Apple's schema: a payload carries either Authorization or
            // Allowed, never both. Authorization is the modern spelling.
            "Authorization": decision.authorization.rawValue,
        ]

        if decision.service == .appleEvents {
            // All three receiver keys are required for AppleEvents. Without a
            // receiver there is no valid entry to write, so the service is
            // dropped and the UI reports it.
            guard plan.appleEventsReceiver.isComplete else { return nil }
            entry["AEReceiverIdentifier"] = plan.appleEventsReceiver.identifier
            entry["AEReceiverIdentifierType"] = "bundleID"
            entry["AEReceiverCodeRequirement"] = plan.appleEventsReceiver.codeRequirement
        }

        return entry
    }
}
