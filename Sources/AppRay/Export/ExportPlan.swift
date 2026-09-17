import Foundation

/// The `Authorization` value of a PPPC service entry.
enum ServiceAuthorization: String, CaseIterable, Identifiable, Sendable {
    case allow = "Allow"
    case deny = "Deny"
    case allowStandardUser = "AllowStandardUserToSetSystemService"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .allow: "Allow"
        case .deny: "Deny"
        case .allowStandardUser: "User may decide"
        }
    }
}

/// Where the Apple Events a service sends are going. Apple's schema makes all
/// three receiver keys required for the `AppleEvents` service, so without a
/// receiver the entry cannot be written at all.
struct AppleEventsReceiver: Hashable, Sendable {
    var identifier: String = ""
    var codeRequirement: String = ""

    var isComplete: Bool {
        !identifier.trimmingCharacters(in: .whitespaces).isEmpty
            && !codeRequirement.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// One admin decision about one service.
struct ServiceDecision: Hashable, Sendable, Identifiable {
    var id: String { service.rawValue }
    var service: PrivilegeService
    var isIncluded: Bool
    var authorization: ServiceAuthorization
    /// For `Location` only: `WhileUsing` or `Always`.
    var locationMode: String = "Always"

    /// A decision the PPPC profile is able to express.
    var isRepresentableInPPPC: Bool {
        guard isIncluded, service.pppcServiceKey != nil else { return false }
        switch service.pppcSupport {
        case .grantAndDeny: return true
        case .denyOnly: return authorization == .deny
        case .unsupported: return false
        }
    }

    /// A decision the DDM declaration is able to express. `Privacy` keys only
    /// pre-seed a positive answer; there is no way to express a denial.
    var isRepresentableInDDM: Bool {
        isIncluded && service.ddmPrivacyKey != nil && authorization == .allow
    }

    /// Why a channel cannot carry this decision — shown next to the row so the
    /// omission is never silent.
    func exclusionReason(for channel: ExportChannel) -> String? {
        guard isIncluded else { return nil }
        switch channel {
        case .pppc where isRepresentableInPPPC: return nil
        case .ddm where isRepresentableInDDM: return nil
        case .pppc:
            if service.pppcServiceKey == nil {
                return "No PPPC key exists for this service."
            }
            return "A PPPC profile can only deny \(service.displayName)."
        case .ddm:
            if service.ddmPrivacyKey == nil {
                return "No DDM privacy key exists for this service."
            }
            return "DDM privacy keys can only pre-approve, never deny."
        }
    }
}

enum ExportChannel: String, CaseIterable, Identifiable, Sendable {
    case pppc
    case ddm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pppc: "PPPC profile"
        case .ddm: "DDM declaration"
        }
    }

    var subtitle: String {
        switch self {
        case .pppc: "com.apple.TCC.configuration-profile-policy · macOS 10.14+"
        case .ddm: "com.apple.configuration.app.settings · macOS 27+, supervised"
        }
    }

    var fileExtension: String {
        switch self {
        case .pppc: "mobileconfig"
        case .ddm: "json"
        }
    }
}

/// Everything the two builders need, kept in one value so the live preview is
/// a pure function of it. The UUIDs are generated once, when the plan is
/// created, so re-rendering the preview does not churn them.
struct ExportPlan: Hashable, Sendable {
    var decisions: [ServiceDecision]
    var organization: String
    var payloadIdentifierPrefix: String
    var displayName: String
    var descriptionText: String
    var organizationJustification: String
    var appleEventsReceiver: AppleEventsReceiver
    let profileUUID: UUID
    let payloadUUID: UUID
    let declarationIdentifier: UUID
    let serverToken: UUID

    init(app: AnalyzedApp) {
        let name = app.info.name
        // Start from what the analyzer actually found, pre-selecting only the
        // things the app declares. Inferences and judgement calls are listed
        // but left switched off — the admin opts in.
        decisions = app.findings.map { finding in
            ServiceDecision(
                service: finding.service,
                isIncluded: finding.confidence == .declared,
                authorization: finding.service.pppcSupport == .denyOnly ? .deny : .allow
            )
        }
        organization = ""
        payloadIdentifierPrefix = "com.example.pppc"
        displayName = "Privacy — \(name)"
        descriptionText = "Privacy Preferences Policy Control for \(name)."
        organizationJustification = "\(name) needs this access to do its job."
        appleEventsReceiver = AppleEventsReceiver()
        profileUUID = UUID()
        payloadUUID = UUID()
        declarationIdentifier = UUID()
        serverToken = UUID()
    }

    subscript(service: PrivilegeService) -> ServiceDecision? {
        get { decisions.first { $0.service == service } }
        set {
            guard let newValue, let index = decisions.firstIndex(where: { $0.service == service })
            else { return }
            decisions[index] = newValue
        }
    }

    func decisions(representableIn channel: ExportChannel) -> [ServiceDecision] {
        decisions.filter { decision in
            switch channel {
            case .pppc: decision.isRepresentableInPPPC
            case .ddm: decision.isRepresentableInDDM
            }
        }
    }

    /// Included decisions that the given channel silently cannot carry.
    func omissions(in channel: ExportChannel) -> [(decision: ServiceDecision, reason: String)] {
        decisions.compactMap { decision in
            decision.exclusionReason(for: channel).map { (decision, $0) }
        }
    }
}
