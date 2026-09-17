import Foundation
import Testing

@testable import AppRay

/// Analyses a real application and validates the two exports with the same
/// tools an MDM would: `plutil` for the profile, `JSONSerialization` for the
/// declaration.
@Suite("End to end")
struct EndToEndTests {
    /// The first installed app that declares enough to export something.
    private static let candidates = [
        "/Applications/Google Chrome.app",
        "/Applications/zoom.us.app",
        "/Applications/Slack.app",
        "/System/Applications/Photo Booth.app",
        "/System/Applications/Messages.app",
    ]

    private static var installed: URL? {
        candidates
            .first { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private func plutilAccepts(_ data: Data) throws -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pi-\(UUID().uuidString).mobileconfig")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        process.arguments = ["-lint", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @Test(
        "A real app produces a profile plutil accepts and a declaration that parses",
        .enabled(if: EndToEndTests.installed != nil)
    )
    func realAppRoundTrip() throws {
        let url = try #require(Self.installed)
        let app = try AppAnalyzer.analyzeSynchronously(url: url)

        #expect(app.info.bundleIdentifier != nil)
        #expect(app.signature.designatedRequirement != nil)
        #expect(app.ddmComposedIdentifier?.hasSuffix("}") == true)
        #expect(!app.findings.isEmpty)

        var plan = ExportPlan(app: app)
        // Turn everything on so both builders get exercised, and give Apple
        // Events the receiver its schema demands.
        for index in plan.decisions.indices {
            plan.decisions[index].isIncluded = true
        }
        plan.appleEventsReceiver = AppleEventsReceiver(
            identifier: "com.apple.finder",
            codeRequirement: #"identifier "com.apple.finder" and anchor apple"#
        )

        let profile = try PPPCProfileBuilder.build(app: app, plan: plan)
        #expect(try plutilAccepts(profile), "plutil rejected the generated profile")

        let declaration = try DDMDeclarationBuilder.build(app: app, plan: plan)
        let json = try #require(
            try JSONSerialization.jsonObject(with: declaration) as? [String: Any]
        )
        let defaults = try #require(
            ((json["Payload"] as? [String: Any])?["Privacy"] as? [String: Any])?["PermissionDefaults"]
                as? [String: Any]
        )
        // Exactly one app, keyed by the composed identifier, and the required
        // justification is present.
        #expect(defaults.count == 1)
        let entry = try #require(defaults[app.ddmComposedIdentifier!] as? [String: Any])
        #expect(entry["OrganizationJustification"] as? String != nil)

        // Every remaining key must be a documented privacy key with a
        // documented value — a typo here is the kind of thing an MDM accepts
        // and a device silently ignores.
        let allowedKeys = Set(PrivilegeService.allCases.compactMap(\.ddmPrivacyKey))
        for (key, value) in entry where key != "OrganizationJustification" {
            #expect(allowedKeys.contains(key), "\(key) is not a documented privacy key")
            let string = try #require(value as? String)
            #expect(["Allow", "WhileUsing", "Always"].contains(string))
        }
    }

    @Test(
        "Analysing a large bundle stays interactive",
        .enabled(if: EndToEndTests.installed != nil),
        .timeLimit(.minutes(1))
    )
    func analysisIsReasonablyFast() throws {
        let url = try #require(Self.installed)
        let start = ContinuousClock.now
        _ = try AppAnalyzer.analyzeSynchronously(url: url)
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(20), "analysis took \(elapsed)")
    }
}
