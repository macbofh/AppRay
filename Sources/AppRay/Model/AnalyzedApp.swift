import Foundation

/// Everything read out of `Contents/Info.plist`.
struct BundleInfo: Hashable, Sendable {
    var url: URL
    var name: String
    var displayName: String?
    var bundleIdentifier: String?
    var shortVersion: String?
    var buildVersion: String?
    var minimumSystemVersion: String?
    var applicationCategory: String?
    var executableName: String?
    var copyright: String?
    var isAgent: Bool
    var urlSchemes: [String]
    var raw: [String: PlistValue]

    /// "1.2.3 (456)", or whichever half is present.
    var versionSummary: String? {
        switch (shortVersion, buildVersion) {
        case let (short?, build?) where short != build: "\(short) (\(build))"
        case let (short?, _): short
        case let (nil, build?): build
        default: nil
        }
    }
}

struct CertificateInfo: Hashable, Sendable, Identifiable {
    var id: Int
    var summary: String
    var expiryDate: Date?
}

/// The result of reading the code signature through Security.framework.
struct CodeSignature: Hashable, Sendable {
    /// Set when the bundle is unsigned or the signature could not be read.
    var failure: String?
    var signingIdentifier: String?
    var teamIdentifier: String?
    /// The 40-character hex code directory hash. Feeds DDM binary identifiers.
    var cdHash: String?
    /// The designated requirement string — the value a PPPC `CodeRequirement`
    /// needs, and the part inside the braces of a DDM composed identifier.
    var designatedRequirement: String?
    var entitlements: [String: PlistValue]
    var certificates: [CertificateInfo]
    var signedDate: Date?
    var isAdHoc: Bool
    var hasHardenedRuntime: Bool
    var hasLibraryValidation: Bool
    var flags: UInt32

    var isSigned: Bool { failure == nil }

    /// The signing authority, e.g. "Developer ID Application: Example (ABCDE12345)".
    var authority: String? { certificates.first?.summary }

    static let unreadable = CodeSignature(
        failure: "No code signature found.",
        entitlements: [:],
        certificates: [],
        isAdHoc: false,
        hasHardenedRuntime: false,
        hasLibraryValidation: false,
        flags: 0
    )
}

/// What Gatekeeper thinks of the bundle.
enum GatekeeperVerdict: Hashable, Sendable {
    case accepted(source: String)
    case rejected(reason: String)
    case unknown(String)

    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

struct GatekeeperStatus: Hashable, Sendable {
    var verdict: GatekeeperVerdict
    /// Whether a notarization ticket is stapled to the bundle itself. An app
    /// can still be notarized without a stapled ticket, in which case macOS
    /// checks online — so a `false` here is not proof of anything.
    var hasStapledTicket: Bool

    static let unknown = GatekeeperStatus(
        verdict: .unknown("Not evaluated."),
        hasStapledTicket: false
    )
}

/// Load-command facts about the main executable.
struct MachOInfo: Hashable, Sendable {
    var architectures: [String]
    var linkedLibraries: [String]
    var minimumOSVersion: String?
    var sdkVersion: String?

    /// Framework names without path or extension, for catalog matching.
    var linkedFrameworkNames: Set<String> {
        Set(linkedLibraries.compactMap { path in
            let name = (path as NSString).lastPathComponent
            return name.hasSuffix(".dylib") ? nil : name
        })
    }

    static let empty = MachOInfo(architectures: [], linkedLibraries: [])
}

/// A nested executable inside the bundle that carries privileges of its own —
/// a privileged helper, login item, XPC service, system extension or plug-in.
struct BundleComponent: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable {
        case privilegedHelper = "Privileged helper"
        case loginItem = "Login item"
        case xpcService = "XPC service"
        case systemExtension = "System extension"
        case plugIn = "Plug-in"
        case helperApp = "Helper app"

        var symbolName: String {
            switch self {
            case .privilegedHelper: "lock.shield"
            case .loginItem: "power"
            case .xpcService: "cube.transparent"
            case .systemExtension: "puzzlepiece.extension"
            case .plugIn: "square.stack.3d.up"
            case .helperApp: "app.badge"
            }
        }
    }

    var id: URL { url }
    var url: URL
    var kind: Kind
    var name: String
    var bundleIdentifier: String?
    var teamIdentifier: String?
    var designatedRequirement: String?
    var cdHash: String?
}

/// Why the analyzer believes an app uses a privilege.
struct Evidence: Hashable, Sendable, Identifiable {
    enum Source: String, Sendable {
        case infoPlistKey = "Info.plist"
        case entitlement = "Entitlement"
        case linkedFramework = "Linked framework"
        case bundleComponent = "Bundle component"
    }

    var id: String { "\(source.rawValue).\(key)" }
    var source: Source
    var key: String
    /// The declared purpose string, entitlement value, or similar.
    var detail: String?
}

/// How sure the analyzer is.
enum Confidence: Int, Comparable, Sendable, CaseIterable {
    /// The app declares it outright: a usage description or an entitlement.
    case declared = 2
    /// Derived from a weaker signal, usually framework linkage.
    case inferred = 1
    /// Leaves no trace in the bundle. Only the admin can decide.
    case manual = 0

    static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .declared: "Declared by the app"
        case .inferred: "Inferred from the binary"
        case .manual: "Requires your judgement"
        }
    }

    var explanation: String {
        switch self {
        case .declared:
            "The bundle states this outright, through a usage description or an entitlement."
        case .inferred:
            "The binary links a framework that needs this, but the bundle never declares it. Verify before shipping."
        case .manual:
            "Nothing in a bundle reveals this. Only include it if you know the app needs it."
        }
    }

    var symbolName: String {
        switch self {
        case .declared: "checkmark.seal"
        case .inferred: "questionmark.circle"
        case .manual: "hand.raised"
        }
    }
}

struct PrivilegeFinding: Hashable, Sendable, Identifiable {
    var id: String { service.rawValue }
    var service: PrivilegeService
    var confidence: Confidence
    var evidence: [Evidence]
}

/// The complete analysis of one application bundle.
struct AnalyzedApp: Hashable, Sendable, Identifiable {
    var id: URL { info.url }
    var info: BundleInfo
    var signature: CodeSignature
    /// `nil` while the Gatekeeper assessment is still running — `spctl` needs
    /// several seconds on a large bundle, so the rest of the analysis does not
    /// wait for it.
    var gatekeeper: GatekeeperStatus?
    var machO: MachOInfo
    var components: [BundleComponent]
    var findings: [PrivilegeFinding]

    /// The key a DDM `Privacy.PermissionDefaults` dictionary expects on macOS:
    /// the bundle ID, a space, then the designated requirement in braces.
    ///
    /// Apple's example: `com.example.app {anchor apple generic}`.
    var ddmComposedIdentifier: String? {
        guard let bundleIdentifier = info.bundleIdentifier,
              let requirement = signature.designatedRequirement
        else { return nil }
        return "\(bundleIdentifier) {\(requirement)}"
    }

    var findingsByConfidence: [(confidence: Confidence, findings: [PrivilegeFinding])] {
        Confidence.allCases
            .sorted(by: >)
            .map { confidence in
                (confidence, findings.filter { $0.confidence == confidence })
            }
            .filter { !$0.1.isEmpty }
    }
}
