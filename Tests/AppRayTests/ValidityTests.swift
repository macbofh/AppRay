import Foundation
import Security
import Testing

@testable import AppRay

@Suite("Certificate validity")
struct CertificateValidityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func status(fromNow days: Int, startedDaysAgo: Int = 365) -> CertificateValidity {
        CertificateValidity.status(
            notBefore: now.addingTimeInterval(TimeInterval(-startedDaysAgo * 86_400)),
            notAfter: now.addingTimeInterval(TimeInterval(days * 86_400)),
            now: now
        )
    }

    @Test("A certificate well inside its window is plainly valid")
    func comfortablyValid() {
        #expect(status(fromNow: 400) == .valid(daysRemaining: 400))
    }

    @Test("The warning window starts 60 days out, inclusive")
    func warningWindowBoundary() {
        #expect(status(fromNow: 61) == .valid(daysRemaining: 61))
        #expect(status(fromNow: 60) == .expiringSoon(daysRemaining: 60))
        #expect(status(fromNow: 1) == .expiringSoon(daysRemaining: 1))
    }

    @Test("Past the end date it reports how long ago")
    func expired() {
        #expect(status(fromNow: -3) == .expired(daysAgo: 3))
        #expect(status(fromNow: -3).isExpired)
    }

    @Test("A certificate that has not started yet is not simply valid")
    func notYetValid() {
        let validity = CertificateValidity.status(
            notBefore: now.addingTimeInterval(86_400),
            notAfter: now.addingTimeInterval(86_400 * 400),
            now: now
        )
        #expect(validity == .notYetValid)
    }

    @Test("Without an end date there is nothing to claim")
    func unknownWithoutDates() {
        #expect(CertificateValidity.status(notBefore: nil, notAfter: nil, now: now) == .unknown)
    }
}

@Suite("Expiry versus secure timestamp")
struct ExpiryBlockerTests {
    private func signature(expiredDaysAgo: Int?, timestamped: Bool) -> CodeSignature {
        let expiry = expiredDaysAgo.map {
            Date.now.addingTimeInterval(TimeInterval(-$0 * 86_400))
        }
        return CodeSignature(
            signingIdentifier: "com.example.app",
            entitlements: [:],
            certificates: [
                CertificateInfo(
                    id: 0,
                    summary: "Developer ID Application: Example",
                    notBefore: Date.now.addingTimeInterval(-86_400 * 1_000),
                    expiryDate: expiry ?? Date.now.addingTimeInterval(86_400 * 500)
                ),
            ],
            signedDate: timestamped ? Date.now.addingTimeInterval(-86_400 * 700) : nil,
            isAdHoc: false,
            hasHardenedRuntime: true,
            hasLibraryValidation: true,
            flags: 0
        )
    }

    @Test("An expired certificate with a secure timestamp does not break the app")
    func expiredButTimestamped() {
        let signature = signature(expiredDaysAgo: 30, timestamped: true)
        #expect(signature.leafCertificate?.validity.isExpired == true)
        #expect(signature.hasSecureTimestamp)
        // This is the whole point: expiry alone is not a failure.
        #expect(!signature.isExpiryABlocker)
    }

    @Test("An expired certificate without a timestamp does break the app")
    func expiredWithoutTimestamp() {
        let signature = signature(expiredDaysAgo: 30, timestamped: false)
        #expect(signature.isExpiryABlocker)
    }

    @Test("A live certificate is never a blocker, timestamp or not")
    func notExpired() {
        #expect(!signature(expiredDaysAgo: nil, timestamped: false).isExpiryABlocker)
        #expect(!signature(expiredDaysAgo: nil, timestamped: true).isExpiryABlocker)
    }
}

@Suite("Notarization status")
struct NotarizationStatusTests {
    @Test("\"Unnotarized Developer ID\" must not be read as notarized")
    func unnotarizedIsNotASubstringMatch() {
        // The trap: "Unnotarized Developer ID" contains "Notarized".
        #expect(NotarizationStatus.from(source: "Unnotarized Developer ID") == .notNotarized)
    }

    @Test("The sources spctl actually prints map to a status")
    func knownSources() {
        #expect(NotarizationStatus.from(source: "Notarized Developer ID") == .notarized)
        #expect(NotarizationStatus.from(source: "Apple System") == .appleSystem)
        #expect(NotarizationStatus.from(source: "Apple") == .appleSystem)
        #expect(NotarizationStatus.from(source: "Mac App Store") == .appStore)
    }

    @Test("An unrecognised source keeps its text rather than claiming anything")
    func unknownKeepsSource() {
        #expect(NotarizationStatus.from(source: "Some Future Rule") == .unknown("Some Future Rule"))
        #expect(NotarizationStatus.from(source: nil) == .unknown("No assessment source."))
    }

    @Test("Only a genuinely unnotarized app is flagged as a concern")
    func concern() {
        #expect(NotarizationStatus.notNotarized.isConcern)
        #expect(!NotarizationStatus.notarized.isConcern)
        #expect(!NotarizationStatus.appleSystem.isConcern)
    }
}

/// The statuses macOS returns when it never evaluated the seal, as opposed to
/// when the seal failed. Getting this wrong is what made AppRay report tampering
/// it had not detected, with nothing under "What changed since signing".
@Suite("Unverifiable signatures")
struct UnverifiableSignatureTests {
    @Test("An obsolete resource envelope is a fact about the format, not the files")
    func obsoleteEnvelope() {
        // Strict validation refuses to read either envelope, so neither ever
        // carries a list of offending files.
        #expect(CodeSignatureReader.obstacle(for: errSecCSWeakResourceRules) == .obsoleteEnvelope)
        #expect(CodeSignatureReader.obstacle(for: errSecCSWeakResourceEnvelope) == .obsoleteEnvelope)
    }

    @Test("A bundle shape macOS will not read has no seal to check")
    func unreadableBundle() {
        #expect(CodeSignatureReader.obstacle(for: errSecCSBadBundleFormat) == .unreadableBundle)
    }

    @Test("A genuine seal failure stays a seal failure")
    func genuineFailuresAreNotExcused() {
        // These are the statuses the tamper report is built for. Routing any of
        // them away from .invalid would lose the findings.
        for status in [
            errSecCSBadResource,
            errSecCSSignatureFailed,
            errSecCSBadMainExecutable,
            errSecCSBadNestedCode,
            errSecCSInfoPlistFailed,
            errSecCSUnsigned,
            errSecSuccess,
        ] {
            #expect(CodeSignatureReader.obstacle(for: status) == nil, "status \(status)")
        }
    }

    @Test("An unverifiable bundle produces no tamper report to paste into a ticket")
    func noTamperReport() {
        var app = AnalyzedApp(
            info: BundleInfo(
                layout: .macOS(bundleURL: URL(fileURLWithPath: "/Applications/Example.app")),
                name: "Example",
                isAgent: false,
                urlSchemes: [],
                raw: [:]
            ),
            signature: .unreadable,
            trust: TrustAssessment(
                gatekeeper: .unknown,
                signatureValidity: .unverifiable(.obsoleteEnvelope)
            ),
            machO: .empty,
            components: [],
            findings: []
        )
        #expect(app.tamperReportText == nil)

        app.trust = TrustAssessment(
            gatekeeper: .unknown,
            signatureValidity: .unverifiable(.unreadableBundle)
        )
        #expect(app.tamperReportText == nil)
    }
}

@Suite("Signature verification against real bundles")
struct SignatureVerificationTests {
    @Test(
        "An untouched system app verifies",
        .enabled(if: FileManager.default.fileExists(atPath: "/System/Applications/Calculator.app"))
    )
    func systemAppIsValid() {
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        #expect(CodeSignatureReader.validate(at: url) == .valid)
    }

    @Test("A modified bundle fails verification")
    func tamperedBundleIsInvalid() throws {
        // AppRay's own bundle, rather than a system app: copying an app off the
        // sealed system volume breaks strict validation on its own, which would
        // make the test pass for the wrong reason.
        let source = Bundle.main.bundleURL
        try #require(source.pathExtension == "app", "the test host should be the app bundle")

        let copy = FileManager.default.temporaryDirectory
            .appending(path: "AppRayTamper-\(UUID().uuidString).app")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        #expect(CodeSignatureReader.validate(at: copy) == .valid, "the untouched copy should verify")

        // Add a file to the sealed resources; the seal must no longer match.
        try Data("tampered".utf8).write(to: copy.appending(path: "Contents/Resources/appray-test.txt"))

        let validity = CodeSignatureReader.validate(at: copy)
        #expect(validity != .valid)
        if case .invalid(let reason, let tamper) = validity {
            #expect(!reason.isEmpty)
            #expect(tamper.findings.contains { $0.kind == .added })
        } else {
            Issue.record("expected .invalid, got \(validity)")
        }
    }

    @Test(
        "A real Developer ID app reports a certificate window and a notarization status",
        .enabled(if: FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app"))
    )
    func realDeveloperIDApp() {
        let url = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let signature = CodeSignatureReader.read(at: url)
        let leaf = signature.leafCertificate

        #expect(leaf?.notBefore != nil)
        #expect(leaf?.expiryDate != nil)
        #expect(leaf?.validity != .unknown)

        let gatekeeper = GatekeeperReader.read(at: url)
        // A shipping browser is notarized; anything else here is a real finding.
        #expect(gatekeeper.notarization == .notarized)
        #expect(gatekeeper.verdict.isAccepted)
    }
}
