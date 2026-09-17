import Foundation

/// Everything read out of the bundle's `Info.plist`.
struct BundleInfo: Hashable, Sendable {
    /// Where this bundle keeps its pieces, and which platform's shape it is.
    var layout: BundleLayout
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

    /// The bundle the user pointed at — the wrapper, when there is one, so
    /// Finder and the icon still refer to something the user recognises.
    var url: URL { layout.droppedURL }

    var platform: BundlePlatform { layout.platform }

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

/// Where a certificate sits in its validity window.
enum CertificateValidity: Hashable, Sendable {
    case valid(daysRemaining: Int)
    /// Inside the window, but not for much longer.
    case expiringSoon(daysRemaining: Int)
    case expired(daysAgo: Int)
    case notYetValid
    case unknown

    /// Days before expiry at which an admin should start caring.
    static let warningWindow = 60

    static func status(notBefore: Date?, notAfter: Date?, now: Date = .now) -> CertificateValidity {
        guard let notAfter else { return .unknown }
        if let notBefore, now < notBefore { return .notYetValid }

        let days = Calendar.current.dateComponents([.day], from: now, to: notAfter).day ?? 0
        if days < 0 { return .expired(daysAgo: -days) }
        return days <= warningWindow ? .expiringSoon(daysRemaining: days) : .valid(daysRemaining: days)
    }

    var isExpired: Bool {
        if case .expired = self { return true }
        return false
    }

    var summary: String {
        switch self {
        case .valid(let days): "Valid, \(days) days remaining"
        case .expiringSoon(let days): days == 1 ? "Expires tomorrow" : "Expires in \(days) days"
        case .expired(let days): days == 1 ? "Expired yesterday" : "Expired \(days) days ago"
        case .notYetValid: "Not valid yet"
        case .unknown: "Validity dates unavailable"
        }
    }
}

struct CertificateInfo: Hashable, Sendable, Identifiable {
    var id: Int
    var summary: String
    var notBefore: Date?
    var expiryDate: Date?

    var validity: CertificateValidity {
        CertificateValidity.status(notBefore: notBefore, notAfter: expiryDate)
    }
}

/// Whether the signature still matches what is on disk.
enum SignatureValidity: Hashable, Sendable {
    case valid
    /// The signature is broken, or the bundle was modified after signing. The
    /// report names every file that no longer matches, so the failure is an
    /// explanation rather than a dead end.
    case invalid(reason: String, tamper: TamperReport)
    case unsigned

    var isValid: Bool { self == .valid }
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

    /// The certificate the app was actually signed with, as opposed to the
    /// intermediates and the root above it.
    var leafCertificate: CertificateInfo? { certificates.first }

    /// A trusted timestamp from Apple's timestamp server, present when the app
    /// was signed with `--timestamp`.
    ///
    /// This is the fact that decides whether an expired signing certificate
    /// matters: with a secure timestamp the signature stays valid past the
    /// certificate's expiry, without one it does not.
    var hasSecureTimestamp: Bool { signedDate != nil }

    /// True when the certificate has expired *and* nothing vouches for when
    /// the app was signed — the combination that actually breaks an app.
    var isExpiryABlocker: Bool {
        (leafCertificate?.validity.isExpired ?? false) && !hasSecureTimestamp
    }

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

/// Whether the app has been through Apple's notarization service.
///
/// Derived from the `source=` line `spctl` prints, which names the rule that
/// accepted the app — the one place macOS states this outright.
enum NotarizationStatus: Hashable, Sendable {
    case notarized
    /// Signed with a Developer ID but never submitted. Gatekeeper blocks these
    /// on a Mac that has not seen the app before.
    case notNotarized
    /// Apple's own software, which does not go through notarization.
    case appleSystem
    case appStore
    case unknown(String)

    static func from(source: String?) -> NotarizationStatus {
        guard let source else { return .unknown("No assessment source.") }
        // Order matters: "Unnotarized Developer ID" contains "Notarized".
        if source.localizedCaseInsensitiveContains("unnotarized") { return .notNotarized }
        if source.localizedCaseInsensitiveContains("notarized") { return .notarized }
        if source.localizedCaseInsensitiveContains("app store") { return .appStore }
        if source.localizedCaseInsensitiveContains("apple system")
            || source.caseInsensitiveCompare("apple") == .orderedSame { return .appleSystem }
        return .unknown(source)
    }

    var label: String {
        switch self {
        case .notarized: "Notarized"
        case .notNotarized: "Not notarized"
        case .appleSystem: "Apple system software"
        case .appStore: "Mac App Store"
        case .unknown: "Notarization unknown"
        }
    }

    /// Whether the absence of notarization is a problem worth flagging.
    var isConcern: Bool { self == .notNotarized }
}

struct GatekeeperStatus: Hashable, Sendable {
    var verdict: GatekeeperVerdict
    var notarization: NotarizationStatus
    /// Whether a notarization ticket is stapled to the bundle itself. An app
    /// can still be notarized without a stapled ticket, in which case macOS
    /// checks online — so a `false` here is not proof of anything.
    var hasStapledTicket: Bool

    static let unknown = GatekeeperStatus(
        verdict: .unknown("Not evaluated."),
        notarization: .unknown("Not evaluated."),
        hasStapledTicket: false
    )
}

/// The `com.apple.quarantine` extended attribute macOS puts on downloaded
/// files. Its presence is what makes Gatekeeper assess the app on first
/// launch; apps installed by an MDM do not carry it.
struct QuarantineInfo: Hashable, Sendable {
    /// The app that downloaded the file, e.g. "Safari".
    var agentName: String?
    /// When the attribute was applied.
    var timestamp: Date?
}

/// The checks that need real work: verifying every sealed resource in the
/// bundle, and asking Gatekeeper for a verdict.
struct TrustAssessment: Hashable, Sendable {
    var gatekeeper: GatekeeperStatus
    var signatureValidity: SignatureValidity
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
        /// An iOS `.appex`: a share sheet, a widget, a keyboard.
        case appExtension = "App extension"
        /// A watchOS app embedded in an iPhone app.
        case watchApp = "Watch app"

        var symbolName: String {
            switch self {
            case .privilegedHelper: "lock.shield"
            case .loginItem: "power"
            case .xpcService: "cube.transparent"
            case .systemExtension: "puzzlepiece.extension"
            case .plugIn: "square.stack.3d.up"
            case .helperApp: "app.badge"
            case .appExtension: "puzzlepiece"
            case .watchApp: "applewatch"
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
    /// `nil` while the slow checks are still running — verifying a large bundle
    /// takes seconds, so the rest of the analysis does not wait for it.
    var trust: TrustAssessment?
    /// `nil` when the bundle carries no quarantine attribute.
    var quarantine: QuarantineInfo?
    var machO: MachOInfo
    var components: [BundleComponent]
    var findings: [PrivilegeFinding]

    var gatekeeper: GatekeeperStatus? { trust?.gatekeeper }
    var signatureValidity: SignatureValidity? { trust?.signatureValidity }

    /// The key a DDM `Privacy.PermissionDefaults` dictionary expects.
    ///
    /// Apple's schema spells out both forms. On macOS it is the bundle ID, a
    /// space, then the designated requirement in braces — the example being
    /// `com.example.app {anchor apple generic}`. On iOS it is the bundle ID on
    /// its own, because iOS has no code requirement to match against.
    var ddmComposedIdentifier: String? {
        guard let bundleIdentifier = info.bundleIdentifier else { return nil }
        guard info.platform == .macOS else { return bundleIdentifier }
        guard let requirement = signature.designatedRequirement else { return nil }
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
