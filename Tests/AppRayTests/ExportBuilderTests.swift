import Foundation
import Testing

@testable import AppRay

/// A minimal app with a designated requirement that contains quotes — the
/// shape that historically breaks hand-written DDM identifiers.
private func makeApp(
    bundleIdentifier: String? = "com.example.app",
    requirement: String? = #"identifier "com.example.app" and anchor apple generic"#,
    findings: [PrivilegeFinding] = []
) -> AnalyzedApp {
    AnalyzedApp(
        info: BundleInfo(
            url: URL(fileURLWithPath: "/Applications/Example.app"),
            name: "Example",
            bundleIdentifier: bundleIdentifier,
            shortVersion: "1.0",
            buildVersion: "100",
            isAgent: false,
            urlSchemes: [],
            raw: [:]
        ),
        signature: CodeSignature(
            signingIdentifier: bundleIdentifier,
            teamIdentifier: "ABCDE12345",
            cdHash: String(repeating: "a", count: 40),
            designatedRequirement: requirement,
            entitlements: [:],
            certificates: [],
            isAdHoc: false,
            hasHardenedRuntime: true,
            hasLibraryValidation: true,
            flags: 0
        ),
        trust: nil,
        quarantine: nil,
        machO: .empty,
        components: [],
        findings: findings
    )
}

private func plan(
    for app: AnalyzedApp,
    including decisions: [(PrivilegeService, ServiceAuthorization)]
) -> ExportPlan {
    var plan = ExportPlan(app: app)
    plan.decisions = decisions.map { service, authorization in
        ServiceDecision(service: service, isIncluded: true, authorization: authorization)
    }
    return plan
}

// MARK: - DDM

@Suite("DDM declaration")
struct DDMDeclarationTests {
    @Test("The composed identifier keeps the requirement verbatim inside braces")
    func composedIdentifier() {
        let identifier = DDMDeclarationBuilder.composedIdentifier(
            bundleIdentifier: "com.example.app",
            designatedRequirement: #"identifier "com.example.app" and anchor apple generic"#
        )
        #expect(identifier == #"com.example.app {identifier "com.example.app" and anchor apple generic}"#)
    }

    @Test("Apple's own documentation example round-trips")
    func appleExample() {
        let identifier = DDMDeclarationBuilder.composedIdentifier(
            bundleIdentifier: "com.example.app",
            designatedRequirement: "anchor apple generic"
        )
        #expect(identifier == "com.example.app {anchor apple generic}")
    }

    @Test("Allowed services land under Privacy.PermissionDefaults with the required justification")
    func declarationShape() throws {
        let app = makeApp()
        var builtPlan = plan(for: app, including: [(.camera, .allow), (.accessibility, .allow)])
        builtPlan.organizationJustification = "Needed for support sessions."

        let data = try DDMDeclarationBuilder.build(app: app, plan: builtPlan)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(json["Type"] as? String == "com.apple.configuration.app.settings")
        #expect(json["Identifier"] as? String != nil)
        #expect(json["ServerToken"] as? String != nil)

        let defaults = try #require(
            ((json["Payload"] as? [String: Any])?["Privacy"] as? [String: Any])?["PermissionDefaults"]
                as? [String: Any]
        )
        let entry = try #require(defaults[app.ddmComposedIdentifier!] as? [String: Any])

        #expect(entry["OrganizationJustification"] as? String == "Needed for support sessions.")
        #expect(entry["Camera"] as? String == "Allow")
        #expect(entry["Accessibility"] as? String == "Allow")
    }

    @Test("Location writes its mode rather than a bare Allow")
    func locationMode() throws {
        let app = makeApp()
        var builtPlan = plan(for: app, including: [(.location, .allow)])
        builtPlan.decisions[0].locationMode = "WhileUsing"

        let data = try DDMDeclarationBuilder.build(app: app, plan: builtPlan)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let defaults = try #require(
            ((json["Payload"] as? [String: Any])?["Privacy"] as? [String: Any])?["PermissionDefaults"]
                as? [String: Any]
        )
        let entry = try #require(defaults.values.first as? [String: Any])
        #expect(entry["Location"] as? String == "WhileUsing")
    }

    @Test("Speech Recognition maps onto the DDM Dictation key")
    func speechRecognitionMapsToDictation() throws {
        let app = makeApp()
        let data = try DDMDeclarationBuilder.build(
            app: app,
            plan: plan(for: app, including: [(.speechRecognition, .allow)])
        )
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"Dictation\""))
        #expect(!text.contains("SpeechRecognition"))
    }

    @Test("A denial cannot be expressed, and is refused rather than silently dropped")
    func denialIsNotRepresentable() {
        let app = makeApp()
        let builtPlan = plan(for: app, including: [(.camera, .deny)])
        #expect(builtPlan.decisions(representableIn: .ddm).isEmpty)
        #expect(throws: ExportError.self) {
            try DDMDeclarationBuilder.build(app: app, plan: builtPlan)
        }
    }

    @Test("Services without a DDM privacy key are reported, not omitted quietly")
    func omissionsAreReported() {
        let app = makeApp()
        let builtPlan = plan(for: app, including: [(.systemPolicyAllFiles, .allow)])
        let omissions = builtPlan.omissions(in: .ddm)
        #expect(omissions.count == 1)
        #expect(omissions[0].reason == "No DDM privacy key exists for this service.")
    }

    @Test("An unsigned app cannot be targeted by identity")
    func unsignedAppFails() {
        let app = makeApp(requirement: nil)
        #expect(throws: ExportError.self) {
            try DDMDeclarationBuilder.build(
                app: app,
                plan: plan(for: app, including: [(.camera, .allow)])
            )
        }
    }
}

// MARK: - PPPC

@Suite("PPPC profile")
struct PPPCProfileTests {
    @Test("The profile is a valid property list with a TCC payload")
    func profileShape() throws {
        let app = makeApp()
        var builtPlan = plan(for: app, including: [(.systemPolicyAllFiles, .allow)])
        builtPlan.organization = "Example B.V."
        builtPlan.payloadIdentifierPrefix = "nl.example.pppc"

        let data = try PPPCProfileBuilder.build(app: app, plan: builtPlan)
        let profile = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        #expect(profile["PayloadType"] as? String == "Configuration")
        // PPPC is device-wide; a user-scoped profile silently does nothing.
        #expect(profile["PayloadScope"] as? String == "System")
        #expect(profile["PayloadIdentifier"] as? String == "nl.example.pppc.com.example.app")

        let payload = try #require((profile["PayloadContent"] as? [[String: Any]])?.first)
        #expect(payload["PayloadType"] as? String == "com.apple.TCC.configuration-profile-policy")

        let services = try #require(payload["Services"] as? [String: [[String: Any]]])
        let entry = try #require(services["SystemPolicyAllFiles"]?.first)

        #expect(entry["Identifier"] as? String == "com.example.app")
        #expect(entry["IdentifierType"] as? String == "bundleID")
        #expect(entry["CodeRequirement"] as? String == app.signature.designatedRequirement)
        #expect(entry["Authorization"] as? String == "Allow")
        // Apple's schema: a payload carries Authorization or Allowed, never both.
        #expect(entry["Allowed"] == nil)
    }

    @Test("Camera can be denied but never granted")
    func cameraIsDenyOnly() throws {
        let app = makeApp()

        let allowPlan = plan(for: app, including: [(.camera, .allow)])
        #expect(allowPlan.decisions(representableIn: .pppc).isEmpty)
        #expect(allowPlan.omissions(in: .pppc).first?.reason == "A PPPC profile can only deny Camera.")

        let denyPlan = plan(for: app, including: [(.camera, .deny)])
        let data = try PPPCProfileBuilder.build(app: app, plan: denyPlan)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("Camera"))
        #expect(text.contains("Deny"))
    }

    @Test("Apple Events is left out until a receiver is supplied")
    func appleEventsNeedsReceiver() throws {
        let app = makeApp()
        var builtPlan = plan(for: app, including: [(.appleEvents, .allow), (.systemPolicyAllFiles, .allow)])

        let withoutReceiver = try PPPCProfileBuilder.build(app: app, plan: builtPlan)
        #expect(!String(decoding: withoutReceiver, as: UTF8.self).contains("AEReceiverIdentifier"))

        builtPlan.appleEventsReceiver = AppleEventsReceiver(
            identifier: "com.apple.finder",
            codeRequirement: "identifier \"com.apple.finder\" and anchor apple"
        )
        let withReceiver = try PPPCProfileBuilder.build(app: app, plan: builtPlan)
        let profile = try #require(
            try PropertyListSerialization.propertyList(from: withReceiver, format: nil) as? [String: Any]
        )
        let payload = try #require((profile["PayloadContent"] as? [[String: Any]])?.first)
        let services = try #require(payload["Services"] as? [String: [[String: Any]]])
        let entry = try #require(services["AppleEvents"]?.first)

        #expect(entry["AEReceiverIdentifier"] as? String == "com.apple.finder")
        #expect(entry["AEReceiverIdentifierType"] as? String == "bundleID")
        #expect(entry["AEReceiverCodeRequirement"] as? String != nil)
    }

    @Test("Location has no PPPC key at all")
    func locationHasNoPPPCKey() {
        let app = makeApp()
        let builtPlan = plan(for: app, including: [(.location, .allow)])
        #expect(builtPlan.decisions(representableIn: .pppc).isEmpty)
        #expect(builtPlan.omissions(in: .pppc).first?.reason == "No PPPC key exists for this service.")
    }
}
