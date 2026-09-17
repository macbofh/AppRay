import SwiftUI

struct ExportSheet: View {
    @Environment(InspectorModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var app: AnalyzedApp

    @State private var plan: ExportPlan
    @State private var channel: ExportChannel = .pppc

    init(app: AnalyzedApp) {
        self.app = app
        _plan = State(initialValue: ExportPlan(app: app))
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                configuration
                    .frame(minWidth: 330, idealWidth: 430)
                preview
                    .frame(minWidth: 330)
            }
            Divider()
            actionBar
        }
        .frame(minWidth: 680, idealWidth: 1_000, minHeight: 520, idealHeight: 660)
    }

    // MARK: - Left: what to include

    private var configuration: some View {
        Form {
            Section {
                ForEach($plan.decisions) { $decision in
                    DecisionRow(decision: $decision, channel: channel)
                }
            } header: {
                Text("Services")
            } footer: {
                Text("Declared privileges start switched on. Inferences and judgement calls do not — turn on only what you know the app needs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isAppleEventsIncluded {
                Section {
                    TextField("Receiving bundle ID", text: $plan.appleEventsReceiver.identifier)
                    TextField("Receiving code requirement", text: $plan.appleEventsReceiver.codeRequirement)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Apple Events receiver")
                } footer: {
                    Text("Apple requires all three receiver keys for the AppleEvents service. Leave these blank and the service is left out of the profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Profile metadata") {
                TextField("Organization", text: $plan.organization)
                TextField("Payload identifier prefix", text: $plan.payloadIdentifierPrefix)
                    .font(.system(.body, design: .monospaced))
                TextField("Display name", text: $plan.displayName)
                TextField("Description", text: $plan.descriptionText, axis: .vertical)
                    .lineLimit(2...4)
            }

            Section {
                TextField(
                    "Justification",
                    text: $plan.organizationJustification,
                    axis: .vertical
                )
                .lineLimit(2...4)
            } header: {
                Text("DDM justification")
            } footer: {
                Text("Required by the declaration, and shown to the user in the consent prompt on the device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var isAppleEventsIncluded: Bool {
        plan[.appleEvents]?.isIncluded ?? false
    }

    // MARK: - Right: what comes out

    private var preview: some View {
        VStack(spacing: 0) {
            Picker("Output", selection: $channel) {
                ForEach(ExportChannel.allCases) { channel in
                    Text(channel.title).tag(channel)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Text(channel.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            if let caveat = channel.caveat(for: app.info.platform) {
                PlatformNotice(text: caveat)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            if !omissions.isEmpty {
                OmissionNotice(omissions: omissions)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            Divider()

            ScrollView([.vertical, .horizontal]) {
                Text(previewText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background.secondary)
        }
    }

    private var previewText: String {
        switch channel {
        case .pppc: PPPCProfileBuilder.preview(app: app, plan: plan)
        case .ddm: DDMDeclarationBuilder.preview(app: app, plan: plan)
        }
    }

    private var omissions: [(decision: ServiceDecision, reason: String)] {
        plan.omissions(in: channel)
    }

    // MARK: - Bottom

    private var actionBar: some View {
        HStack {
            Button("Cancel", role: .cancel) { dismiss() }

            Spacer()

            Button("Copy") {
                model.copy(previewText, label: channel.title)
            }
            .disabled(!canExport)

            Button("Save…") { save() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canExport)
        }
        .padding(12)
    }

    private var canExport: Bool {
        !plan.decisions(representableIn: channel).isEmpty
    }

    private func save() {
        do {
            let data = switch channel {
            case .pppc: try PPPCProfileBuilder.build(app: app, plan: plan)
            case .ddm: try DDMDeclarationBuilder.build(app: app, plan: plan)
            }
            model.write(
                data,
                channel: channel,
                suggestedName: model.suggestedFilename(for: channel)
            )
        } catch {
            model.show(toast: error.localizedDescription)
        }
    }
}

// MARK: - Rows

private struct DecisionRow: View {
    @Binding var decision: ServiceDecision
    var channel: ExportChannel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $decision.isIncluded) {
                HStack(spacing: 8) {
                    Image(systemName: decision.service.symbolName)
                        .foregroundStyle(.tint)
                        .frame(width: 20)
                    Text(decision.service.displayName)
                    Spacer(minLength: 8)
                    ChannelBadges(service: decision.service)
                }
            }
            .toggleStyle(.checkbox)

            if decision.isIncluded {
                HStack(spacing: 10) {
                    Picker("Authorization", selection: $decision.authorization) {
                        ForEach(authorizationOptions) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()

                    if decision.service == .location {
                        Picker("Location", selection: $decision.locationMode) {
                            Text("While using").tag("WhileUsing")
                            Text("Always").tag("Always")
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                .padding(.leading, 28)

                if let reason = decision.exclusionReason(for: channel) {
                    Label(reason, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.leading, 28)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var authorizationOptions: [ServiceAuthorization] {
        var options: [ServiceAuthorization] = [.allow, .deny]
        if decision.service.allowsStandardUserOverride {
            options.append(.allowStandardUser)
        }
        return options
    }
}

/// A limit that applies to the whole output rather than to one service. The
/// omissions below answer "what did you drop"; this answers "will any of this
/// reach the device at all".
private struct PlatformNotice: View {
    var text: String

    var body: some View {
        Label(text, systemImage: "iphone")
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))
    }
}

private struct OmissionNotice: View {
    var omissions: [(decision: ServiceDecision, reason: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                "\(omissions.count) selected \(omissions.count == 1 ? "service is" : "services are") not in this output",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption.weight(.medium))

            ForEach(omissions, id: \.decision.id) { omission in
                Text("\(omission.decision.service.displayName) — \(omission.reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))
    }
}
