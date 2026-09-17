import Foundation
import Testing

@testable import AppRay

/// A tampered iOS bundle taken through the whole app flow rather than through
/// `CodeSignatureReader` alone: an iOS app is the one case where the analysis
/// deliberately skips Gatekeeper, and skipping the seal with it would leave the
/// Signature tab with nothing to say about the shape most likely to be handed
/// round by email.
@Suite("A tampered iOS bundle, end to end")
struct IOSTamperTests {
    private func withFlatBundle<T>(_ body: (URL) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AppRayIOSTamper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(try BundleFixture.flat(in: directory))
    }

    /// The whole flow: resolve the layout, read the bundle, then the background
    /// half that fills the validity rows in.
    private func analyse(_ url: URL) async throws -> AnalyzedApp {
        var app = try AppAnalyzer.analyzeSynchronously(url: url)
        app.trust = await AppAnalyzer.assessTrust(layout: app.info.layout)
        return app
    }

    private func report(_ app: AnalyzedApp) throws -> TamperReport {
        guard case .invalid(_, let tamper) = app.trust?.signatureValidity else {
            Issue.record("expected .invalid, got \(String(describing: app.trust?.signatureValidity))")
            throw CancellationError()
        }
        return tamper
    }

    private func shasum(_ url: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path(percentEncoded: false)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(String(decoding: data, as: UTF8.self).prefix(64))
    }

    @Test("Not asking Gatekeeper does not mean not checking the seal")
    func gatekeeperIsSkippedAndTheSealIsNot() async throws {
        try await withFlatBundle { app in
            let untouched = try await analyse(app)
            #expect(untouched.info.platform == .iOS)
            // Gatekeeper is deliberately not asked about an iOS bundle…
            #expect(untouched.gatekeeper?.verdict == .unknown("Gatekeeper does not assess iOS bundles."))
            // …and the signature is verified anyway.
            #expect(untouched.signatureValidity == .valid)

            try Data("tampered".utf8).write(to: app.appending(path: "data.txt"))

            let modified = try await analyse(app)
            #expect(modified.gatekeeper?.verdict == .unknown("Gatekeeper does not assess iOS bundles."))
            #expect(try !report(modified).isEmpty, "an iOS bundle with no tamper analysis at all")
        }
    }

    @Test("The paths start at the bundle root, with no Contents that was never there")
    func pathsAreBundleRelative() async throws {
        try await withFlatBundle { app in
            let sealed = shasum(app.appending(path: "data.txt"))
            try Data("tampered".utf8).write(to: app.appending(path: "data.txt"))
            try Data("payload".utf8).write(to: app.appending(path: "added.dylib"))

            let tamper = try report(try await analyse(app))
            #expect(tamper.findings.allSatisfy { !$0.path.contains("Contents/") })

            let modified = try #require(tamper.findings.first { $0.kind == .modified })
            #expect(modified.path == "data.txt")
            let digests = try #require(modified.digests)
            #expect(digests.algorithm == "SHA-256")
            // The seal is the hash of the file as it was, and the pair is the
            // claim a vendor checks without AppRay.
            #expect(digests.sealed == sealed)
            #expect(digests.onDisk == shasum(app.appending(path: "data.txt")))

            #expect(tamper.findings.contains { $0.kind == .added && $0.path == "added.dylib" })
        }
    }

    @Test("The report states what a broken signature costs on iOS, not on macOS")
    func reportSpeaksToTheRightPlatform() async throws {
        try await withFlatBundle { app in
            try Data("tampered".utf8).write(to: app.appending(path: "data.txt"))
            let text = try #require(try await analyse(app).tamperReportText)

            #expect(text.contains("iOS will not launch this bundle."))
            #expect(text.contains("Gatekeeper does not assess iOS bundles"))
            #expect(text.contains("keyed by the bundle identifier alone"))

            // The macOS consequences are wrong here: Gatekeeper never sees this
            // bundle, and no PPPC profile reaches an iPhone to go stale.
            #expect(!text.contains("Gatekeeper rejects this bundle"))
            #expect(!text.contains("an MDM profile built from them"))

            // Still reproducible, because codesign reads a flat bundle too.
            #expect(text.contains("codesign --verify --deep --strict -vvvvv"))
            #expect(text.contains("data.txt"))
        }
    }

    @Test("A macOS bundle keeps the consequences it already had")
    func macOSReportIsUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AppRayMacTamper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let app = try BundleFixture.nested(in: directory)
        try Data("tampered".utf8).write(
            to: app.appending(path: "Contents/PlugIns/Inner.appex/Contents/Resources/data.txt")
        )

        var analyzed = try AppAnalyzer.analyzeSynchronously(url: app)
        #expect(analyzed.info.platform == .macOS)
        analyzed.trust = TrustAssessment(
            gatekeeper: .unknown,
            signatureValidity: CodeSignatureReader.validate(at: app)
        )
        let text = try #require(analyzed.tamperReportText)

        #expect(text.contains("Gatekeeper rejects this bundle"))
        #expect(text.contains("an MDM profile built from them targets that app and"))
        #expect(!text.contains("iOS will not launch this bundle."))
    }

    @Test("A tampered iOS app has both notices to put above the export preview")
    func bothNoticesFireAtOnce() async throws {
        try await withFlatBundle { app in
            try Data("tampered".utf8).write(to: app.appending(path: "data.txt"))
            let analyzed = try await analyse(app)

            // The tamper warning, from the validity the analysis just filled in…
            #expect(try !report(analyzed).isEmpty)
            // …and the platform caveat, on whichever channel is on screen.
            #expect(ExportChannel.pppc.caveat(for: analyzed.info.platform) != nil)
            #expect(ExportChannel.ddm.caveat(for: analyzed.info.platform) != nil)

            // The two agree about the same declaration: it is keyed by the
            // bundle identifier alone, which this tampered copy still carries.
            #expect(analyzed.ddmComposedIdentifier == "com.appray.flat")
        }
    }
}
