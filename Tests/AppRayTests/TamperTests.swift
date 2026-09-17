import Foundation
import Testing

@testable import AppRay

/// These build genuinely tampered bundles on disk and check that AppRay names
/// what changed, then hold the result against what `codesign` reports about the
/// same bundle. AppRay's account must not be the shorter of the two.
@Suite("Tamper reporting")
struct TamperTests {
    /// A copy of the test host, tampered with and then validated.
    ///
    /// The test host rather than a system app: copying an app off the sealed
    /// system volume fails strict validation on its own, which would make every
    /// one of these pass for the wrong reason.
    private func validateTamperedCopy(
        _ tamper: (URL) throws -> Void
    ) throws -> (url: URL, validity: SignatureValidity, codesign: String) {
        let source = Bundle.main.bundleURL
        try #require(source.pathExtension == "app", "the test host should be the app bundle")

        let copy = FileManager.default.temporaryDirectory
            .appending(path: "AppRayTamper-\(UUID().uuidString).app")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        #expect(CodeSignatureReader.validate(at: copy) == .valid, "the untouched copy should verify")
        try tamper(copy)

        return (copy, CodeSignatureReader.validate(at: copy), codesign(copy))
    }

    /// `codesign --verify --deep --strict -vvvvv`, for the comparison.
    private func codesign(_ url: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", "-vvvvv", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func report(_ validity: SignatureValidity) throws -> TamperReport {
        guard case .invalid(let reason, let tamper) = validity else {
            Issue.record("expected .invalid, got \(validity)")
            throw CancellationError()
        }
        #expect(!reason.isEmpty)
        return tamper
    }

    @Test("A file whose bytes changed is reported as modified, with its path")
    func modified() throws {
        let result = try validateTamperedCopy { copy in
            let icon = copy.appending(path: "Contents/Resources/AppIcon.icns")
            let handle = try FileHandle(forWritingTo: icon)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("tampered".utf8))
            try handle.close()
        }

        let finding = try #require(try report(result.validity).findings.first { $0.kind == .modified })
        #expect(finding.path == "Contents/Resources/AppIcon.icns")
        // The size and date are the "how", and they only exist for a file that
        // is still on disk.
        #expect(finding.detail != nil)
        #expect(result.codesign.contains("file modified:"))
    }

    @Test("A file the signature never covered is reported as added")
    func added() throws {
        let result = try validateTamperedCopy { copy in
            try Data("payload".utf8)
                .write(to: copy.appending(path: "Contents/Resources/appray-added.txt"))
        }

        let finding = try #require(try report(result.validity).findings.first { $0.kind == .added })
        #expect(finding.path == "Contents/Resources/appray-added.txt")
        #expect(result.codesign.contains("file added:"))
    }

    @Test("A sealed file that is gone is reported as missing")
    func missing() throws {
        let result = try validateTamperedCopy { copy in
            try FileManager.default.removeItem(at: copy.appending(path: "Contents/Resources/Assets.car"))
        }

        let finding = try #require(try report(result.validity).findings.first { $0.kind == .missing })
        #expect(finding.path == "Contents/Resources/Assets.car")
        // Nothing is left to describe, so nothing is claimed.
        #expect(finding.detail == nil)
        #expect(result.codesign.contains("file missing:"))
    }

    @Test("Finder information attached to a sealed file is reported, and named")
    func sideband() throws {
        let result = try validateTamperedCopy { copy in
            let icon = copy.appending(path: "Contents/Resources/AppIcon.icns")
            let value = Data(repeating: 0x41, count: 32)
            let written = value.withUnsafeBytes { bytes in
                setxattr(icon.path(percentEncoded: false), "com.apple.FinderInfo", bytes.baseAddress, 32, 0, 0)
            }
            try #require(written == 0, "the extended attribute should have been set")
        }

        let finding = try #require(try report(result.validity).findings.first { $0.kind == .sideband })
        #expect(finding.path == "Contents/Resources/AppIcon.icns")
        #expect(finding.detail?.contains("com.apple.FinderInfo") == true)
        #expect(result.codesign.contains("com.apple.FinderInfo"))
    }

    @Test("Every offending file is listed, not just the first one found")
    func everyFinding() throws {
        let result = try validateTamperedCopy { copy in
            let icon = copy.appending(path: "Contents/Resources/AppIcon.icns")
            let handle = try FileHandle(forWritingTo: icon)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("tampered".utf8))
            try handle.close()

            try Data("one".utf8).write(to: copy.appending(path: "Contents/Resources/appray-one.txt"))
            try Data("two".utf8).write(to: copy.appending(path: "Contents/Resources/appray-two.txt"))
            try FileManager.default.removeItem(at: copy.appending(path: "Contents/Resources/Assets.car"))
        }

        let tamper = try report(result.validity)
        #expect(tamper.findings.filter { $0.kind == .added }.count == 2)
        #expect(tamper.findings.filter { $0.kind == .modified }.count == 1)
        #expect(tamper.findings.filter { $0.kind == .missing }.count == 1)
        #expect(tamper.findingsByKind.count == 3)
        #expect(tamper.breaksSeal)

        // Not worse than codesign: every path it names must be in the report.
        let reported = Set(tamper.findings.map(\.path))
        for line in result.codesign.split(separator: "\n") where line.hasPrefix("file ") {
            let path = String(line.split(separator: ": ", maxSplits: 1).last ?? "")
            let relative = path.components(separatedBy: result.url.lastPathComponent + "/").last ?? path
            #expect(reported.contains(relative), "codesign named \(relative) and AppRay did not")
        }
    }

    @Test("A bundle that verifies has nothing to report")
    func untouchedCopyIsValid() throws {
        let result = try validateTamperedCopy { _ in }
        #expect(result.validity == .valid)
    }
}

@Suite("The tamper report an admin sends on")
struct TamperReportTextTests {
    private func app(findings: [TamperFinding], reason: String = "A sealed resource is missing or invalid") -> AnalyzedApp {
        var app = AnalyzedApp(
            info: BundleInfo(
                url: URL(fileURLWithPath: "/Applications/Example.app"),
                name: "Example",
                bundleIdentifier: "com.example.app",
                shortVersion: "1.2.3",
                buildVersion: "456",
                isAgent: false,
                urlSchemes: [],
                raw: [:]
            ),
            signature: CodeSignature(
                signingIdentifier: "com.example.app",
                teamIdentifier: "ABCDE12345",
                cdHash: String(repeating: "a", count: 40),
                entitlements: [:],
                certificates: [
                    CertificateInfo(id: 0, summary: "Developer ID Application: Example Ltd"),
                ],
                isAdHoc: false,
                hasHardenedRuntime: true,
                hasLibraryValidation: true,
                flags: 0
            ),
            trust: nil,
            machO: .empty,
            components: [],
            findings: []
        )
        app.trust = TrustAssessment(
            gatekeeper: .unknown,
            signatureValidity: .invalid(reason: reason, tamper: TamperReport(findings: findings))
        )
        return app
    }

    @Test("A verifying bundle produces no report at all")
    func nothingToReport() {
        var app = self.app(findings: [])
        app.trust = TrustAssessment(gatekeeper: .unknown, signatureValidity: .valid)
        #expect(app.tamperReportText == nil)
    }

    @Test("The report identifies the bundle, the verdict, every finding and the consequence")
    func fullReport() throws {
        let app = app(findings: [
            TamperFinding(kind: .modified, path: "Contents/Resources/appView.css", detail: "4 KB, modified 17 Sep 2026 at 14:02"),
            TamperFinding(kind: .added, path: "Contents/Resources/payload.dylib", detail: "2 KB, modified 17 Sep 2026 at 14:02"),
            TamperFinding(kind: .missing, path: "Contents/Resources/AppIcon.icns", detail: nil),
        ])
        let text = try #require(app.tamperReportText)

        // Identity, so the report stands on its own in a ticket.
        #expect(text.contains("/Applications/Example.app"))
        #expect(text.contains("com.example.app"))
        #expect(text.contains("1.2.3 (456)"))
        #expect(text.contains("Developer ID Application: Example Ltd"))
        #expect(text.contains("ABCDE12345"))
        #expect(text.contains(String(repeating: "a", count: 40)))

        // The verdict stays a failure, and says so once.
        #expect(text.contains("does not match its code signature: a sealed resource is missing or invalid"))

        // Every finding, under a heading that counts it.
        #expect(text.contains("Modified since signing — 1"))
        #expect(text.contains("Added since signing — 1"))
        #expect(text.contains("Missing since signing — 1"))
        #expect(text.contains("Contents/Resources/payload.dylib (2 KB, modified 17 Sep 2026 at 14:02)"))

        // The consequence, and how to check it without AppRay.
        #expect(text.contains("Gatekeeper rejects this bundle"))
        #expect(text.contains("codesign --verify --deep --strict -vvvvv \"/Applications/Example.app\""))
    }

    @Test("Attached data alone does not claim Gatekeeper rejects the bundle")
    func sidebandOnlyConsequence() throws {
        let app = app(
            findings: [
                TamperFinding(
                    kind: .sideband,
                    path: "Contents/Resources/AppIcon.icns",
                    detail: "Disallowed xattr com.apple.FinderInfo"
                ),
            ],
            reason: "Resource fork, Finder information, or similar detritus not allowed"
        )
        let text = try #require(app.tamperReportText)

        // Gatekeeper accepts a bundle carrying only this, and the report must
        // not say otherwise.
        #expect(!text.contains("Gatekeeper rejects"))
        #expect(text.contains("Gatekeeper still accepts this bundle"))
        #expect(text.contains("cannot be re-signed"))
    }
}
