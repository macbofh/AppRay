import Foundation

/// Turns a collected list into CSV text — the format admins pass around a
/// team before building a Blueprint entry or a profile from it.
enum CSVExportBuilder {
    private static let header = [
        "Name", "Bundle Identifier", "Platform", "Developer",
        "Team Identifier", "CD Hash", "Designated Requirement", "Source",
    ]

    static func build(entries: [CollectedEntry]) -> String {
        var lines = [header.map(escape).joined(separator: ",")]
        for entry in entries {
            let fields = [
                entry.name,
                entry.bundleIdentifier ?? "",
                entry.platform,
                entry.developerName ?? "",
                entry.teamIdentifier ?? "",
                entry.cdHash ?? "",
                entry.designatedRequirement ?? "",
                entry.source.rawValue,
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
            return field
        }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
