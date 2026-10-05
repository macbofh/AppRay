import SwiftUI

/// The list an admin builds up from analysed apps and App Store lookups
/// before exporting it to CSV to share with a team.
struct CollectionListView: View {
    @Environment(InspectorModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if model.collectedEntries.isEmpty {
                ContentUnavailableView(
                    "No favorites yet",
                    systemImage: "list.bullet.rectangle.portrait",
                    description: Text(
                        "Add an analysed app or an App Store lookup result to build your favorites, then export it to CSV."
                    )
                )
                .frame(maxHeight: .infinity)
            } else {
                Table(model.collectedEntries) {
                    TableColumn("Name") { entry in
                        Button(entry.name) { model.open(entry) }
                            .buttonStyle(.plain)
                            .help("Open \(entry.name)'s details")
                    }
                    TableColumn("Bundle Identifier") { Text($0.bundleIdentifier ?? "—") }
                    TableColumn("Platform", value: \.platform)
                    TableColumn("Version") { Text($0.version ?? "—") }
                    TableColumn("Developer") { Text($0.developerName ?? "—") }
                    TableColumn("Team Identifier") { Text($0.teamIdentifier ?? "—") }
                    TableColumn("CD Hash") {
                        Text($0.cdHash ?? "—")
                            .font(.system(.caption, design: .monospaced))
                    }
                    TableColumn("Source") { Text($0.source.rawValue) }
                    TableColumn("") { entry in
                        Button("Remove", systemImage: "minus.circle") {
                            model.remove(entry)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
            }

            Divider()
            HStack {
                Button("Close", role: .cancel) { dismiss() }
                    .disabled(model.isExportingCSV)
                Spacer()
                Button {
                    Task { await model.exportCollectedEntriesAsCSV() }
                } label: {
                    if model.isExportingCSV {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Analysing…")
                        }
                    } else {
                        Text("Export CSV…")
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(model.collectedEntries.isEmpty || model.isExportingCSV)
            }
            .padding(12)
        }
        .frame(minWidth: 680, idealWidth: 820, minHeight: 360, idealHeight: 480)
    }
}
