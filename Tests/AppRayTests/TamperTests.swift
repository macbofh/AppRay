import Foundation
import Testing

@testable import AppRay

/// These build genuinely tampered bundles on disk and check that AppRay names
/// what changed, then hold the result against what `codesign` and `shasum` say
/// about the same files. AppRay's account must not be the shorter of the two.
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
        run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-vvvvv", url.path])
    }

    /// An implementation of SHA-256 that is not the one under test.
    private func shasum(_ url: URL) -> String {
        String(run("/usr/bin/shasum", ["-a", "256", url.path(percentEncoded: false)]).prefix(64))
    }

    private func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
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
            try append("tampered", to: copy.appending(path: "Contents/Resources/AppIcon.icns"))
        }

        let finding = try #require(try report(result.validity).findings.first { $0.kind == .modified })
        #expect(finding.path == "Contents/Resources/AppIcon.icns")
        // The size and date are the "how", and they only exist for a file that
        // is still on disk.
        #expect(finding.detail != nil)
        #expect(result.codesign.contains("file modified:"))
    }

    @Test("A modified file carries the sealed hash and the hash of what is on disk")
    func modifiedDigests() throws {
        // The hash the untouched file has, taken before anything is done to it.
        let sealedBytes = shasum(
            Bundle.main.bundleURL.appending(path: "Contents/Resources/AppIcon.icns")
        )
        var tamperedBytes = ""

        let result = try validateTamperedCopy { copy in
            let icon = copy.appending(path: "Contents/Resources/AppIcon.icns")
            try append("tampered", to: icon)
            tamperedBytes = shasum(icon)
        }

        let finding = try #require(try report(result.validity).findings.first { $0.kind == .modified })
        let digests = try #require(finding.digests)

        #expect(digests.algorithm == "SHA-256")
        // The manifest sealed the original bytes, and AppRay read that value
        // back out of it rather than inventing one.
        #expect(digests.sealed == sealedBytes)
        #expect(digests.onDisk == tamperedBytes)
        #expect(digests.sealed != digests.onDisk)
        #expect(digests.shortSealed.hasPrefix(String(sealedBytes.prefix(16))))
    }

    @Test("The sealed hash AppRay reports is the one in the manifest")
    func digestMatchesTheManifest() throws {
        let manifest = try #require(
            SealedResourceManifest.read(
                at: Bundle.main.bundleURL
                    .appending(path: "Contents/_CodeSignature/CodeResources")
            )
        )
        let seal = try #require(manifest["Resources/AppIcon.icns"])
        guard case .sha256(let sealed) = seal else {
            Issue.record("expected a SHA-256 seal, got \(seal)")
            return
        }

        let result = try validateTamperedCopy { copy in
            try append("tampered", to: copy.appending(path: "Contents/Resources/AppIcon.icns"))
        }
        let finding = try #require(try report(result.validity).findings.first { $0.kind == .modified })
        #expect(finding.digests?.sealed == sealed)
    }

    @Test("A file the signature never covered is reported as added")
    func added() throws {
        let result = try validateTamperedCopy { copy in
            try Data("payload".utf8)
                .write(to: copy.appending(path: "Contents/Resources/appray-added.txt"))
        }

        let finding = try #require(try report(result.validity).findings.first { $0.kind == .added })
        #expect(finding.path == "Contents/Resources/appray-added.txt")
        // Nothing sealed it, so there is no sealed hash to hold it against.
        #expect(finding.digests == nil)
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
        #expect(finding.digests == nil)
        #expect(result.codesign.contains("file missing:"))
    }

    @Test("Every offending file is listed, not just the first one found")
    func everyFinding() throws {
        let result = try validateTamperedCopy { copy in
            try append("tampered", to: copy.appending(path: "Contents/Resources/AppIcon.icns"))
            try Data("one".utf8).write(to: copy.appending(path: "Contents/Resources/appray-one.txt"))
            try Data("two".utf8).write(to: copy.appending(path: "Contents/Resources/appray-two.txt"))
            try FileManager.default.removeItem(at: copy.appending(path: "Contents/Resources/Assets.car"))
        }

        let tamper = try report(result.validity)
        #expect(tamper.findings.filter { $0.kind == .added }.count == 2)
        #expect(tamper.findings.filter { $0.kind == .modified }.count == 1)
        #expect(tamper.findings.filter { $0.kind == .missing }.count == 1)
        #expect(tamper.findingsByKind.count == 3)

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

/// `CodeResources` seals four different kinds of thing, and only one of them is
/// a hash of a file's bytes. These pin down which is which, because the rest
/// decide what the app is able to say about an offending file.
@Suite("The sealed resource manifest")
struct SealedResourceManifestTests {
    private func manifest(_ files: [String: Any], _ files2: [String: Any]) throws -> SealedResourceManifest {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AppRayManifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appending(path: "CodeResources")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["files": files, "files2": files2],
            format: .xml,
            options: 0
        )
        try data.write(to: url)
        return try #require(SealedResourceManifest.read(at: url))
    }

    private let sha256 = Data(repeating: 0xAB, count: 32)
    private let sha1 = Data(repeating: 0xCD, count: 20)

    @Test("A plain file is sealed by the SHA-256 of its bytes")
    func plainFile() throws {
        let manifest = try manifest([:], ["Resources/a.png": ["hash2": sha256]])
        #expect(manifest["Resources/a.png"] == .sha256(String(repeating: "ab", count: 32)))
        #expect(manifest["Resources/a.png"]?.algorithm == "SHA-256")
    }

    @Test("An entry carrying both digests is read as the newer one")
    func bothDigests() throws {
        let manifest = try manifest(
            ["Resources/a.png": sha1],
            ["Resources/a.png": ["hash": sha1, "hash2": sha256, "optional": true]]
        )
        #expect(manifest["Resources/a.png"]?.algorithm == "SHA-256")
    }

    @Test("A path only an old signature covers falls back to SHA-1")
    func legacyOnly() throws {
        let manifest = try manifest(["Resources/old.png": sha1], [:])
        #expect(manifest["Resources/old.png"] == .sha1(String(repeating: "cd", count: 20)))
        #expect(manifest["Resources/old.png"]?.algorithm == "SHA-1")
    }

    @Test("Nested code has no file hash, and does not pretend to")
    func nestedCode() throws {
        let manifest = try manifest(
            [:],
            ["Frameworks/A.framework": ["cdhash": sha1, "requirement": "anchor apple"]]
        )
        #expect(manifest["Frameworks/A.framework"] == .nestedCode)
        #expect(manifest["Frameworks/A.framework"]?.sealedDigest == nil)
        #expect(manifest["Frameworks/A.framework"]?.algorithm == nil)
    }

    @Test("A symbolic link is sealed by where it points")
    func symlink() throws {
        let manifest = try manifest([:], ["Frameworks/A/Current": ["symlink": "A"]])
        #expect(manifest["Frameworks/A/Current"] == .symlink(target: "A"))
        #expect(manifest["Frameworks/A/Current"]?.sealedDigest == nil)
    }

    @Test("A path the manifest does not list reads as nothing, not as zero")
    func unlisted() throws {
        let manifest = try manifest([:], ["Resources/a.png": ["hash2": sha256]])
        #expect(manifest["Resources/b.png"] == nil)
    }

    @Test("A manifest that is not there cannot be read, and says so by being nil")
    func absent() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "AppRayMissing-\(UUID().uuidString)/CodeResources")
        #expect(SealedResourceManifest.read(at: missing) == nil)
    }

    @Test("A real bundle's manifest parses, and the hash matches the file")
    func realBundle() throws {
        let bundle = Bundle.main.bundleURL
        let manifest = try #require(
            SealedResourceManifest.read(at: bundle.appending(path: "Contents/_CodeSignature/CodeResources"))
        )
        let seal = try #require(manifest["Resources/AppIcon.icns"])
        let onDisk = seal.digestOnDisk(at: bundle.appending(path: "Contents/Resources/AppIcon.icns"))
        // An untouched file hashes to exactly what was sealed.
        #expect(onDisk == seal.sealedDigest)
    }
}

@Suite("The tamper report an admin sends on")
struct TamperReportTextTests {
    private func app(findings: [TamperFinding]) -> AnalyzedApp {
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
            signatureValidity: .invalid(
                reason: "A sealed resource is missing or invalid",
                tamper: TamperReport(findings: findings)
            )
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
        let sealed = String(repeating: "1", count: 64)
        let onDisk = String(repeating: "2", count: 64)
        let app = app(findings: [
            TamperFinding(
                kind: .modified,
                path: "Contents/Resources/appView.css",
                detail: "4 KB, modified 17 Sep 2026 at 14:02",
                digests: .init(algorithm: "SHA-256", sealed: sealed, onDisk: onDisk)
            ),
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
        #expect(text.contains("does not match its code signature: a sealed resource is missing or invalid."))

        // Every finding, under a heading that counts it.
        #expect(text.contains("Modified since signing — 1"))
        #expect(text.contains("Added since signing — 1"))
        #expect(text.contains("Missing since signing — 1"))
        #expect(text.contains("Contents/Resources/payload.dylib (2 KB, modified 17 Sep 2026 at 14:02)"))

        // Both hashes in full, because a report nobody can check is no use.
        #expect(text.contains("sealed SHA-256 \(sealed)"))
        #expect(text.contains("on disk        \(onDisk)"))

        // The consequence, and how to check it without AppRay.
        #expect(text.contains("Gatekeeper rejects this bundle"))
        #expect(text.contains("codesign --verify --deep --strict -vvvvv \"/Applications/Example.app\""))
    }

    @Test("A finding with no sealed hash prints its path and nothing it cannot back up")
    func findingWithoutDigests() throws {
        let app = app(findings: [
            TamperFinding(
                kind: .modified,
                path: "Contents/Frameworks/A.framework",
                detail: "12 KB, modified 17 Sep 2026 at 14:02 — sealed as nested code, by its own signature rather than by a hash of its bytes"
            ),
        ])
        let text = try #require(app.tamperReportText)

        #expect(text.contains("sealed as nested code"))
        #expect(!text.contains("sealed SHA"))
        #expect(!text.contains("on disk "))
    }
}
