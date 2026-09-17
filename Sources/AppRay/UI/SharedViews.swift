import AppKit
import SwiftUI

/// A small pill. Used for team ID, notarization state, confidence and the
/// PPPC/DDM channel markers.
struct Badge: View {
    enum Tone {
        case neutral, positive, caution, critical

        var color: Color {
            switch self {
            case .neutral: .secondary
            case .positive: .green
            case .caution: .orange
            case .critical: .red
            }
        }
    }

    var text: String
    var symbolName: String?
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: 4) {
            if let symbolName {
                Image(systemName: symbolName)
                    .imageScale(.small)
            }
            Text(text)
        }
        .font(.caption)
        .fontWeight(.medium)
        .foregroundStyle(tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tone.color.opacity(tone == .neutral ? 0.10 : 0.14), in: .capsule)
    }
}

/// A labelled value that copies itself on click. Nearly every field in this app
/// exists to be pasted somewhere else, so this is the default presentation.
struct CopyableRow: View {
    @Environment(InspectorModel.self) private var model

    var label: String
    var value: String?
    var isMonospaced = false
    var placeholder = "—"

    @State private var isHovering = false

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(value ?? placeholder)
                    .font(isMonospaced ? .system(.body, design: .monospaced) : .body)
                    .textSelection(.enabled)
                    .foregroundStyle(value == nil ? .tertiary : .primary)
                    .multilineTextAlignment(.trailing)

                Image(systemName: "document.on.document")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .opacity(isHovering && value != nil ? 1 : 0)
            }
        }
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .onTapGesture {
            guard let value else { return }
            model.copy(value, label: label)
        }
        .help(value == nil ? "" : "Click to copy")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(value == nil ? [] : .isButton)
        .accessibilityHint(value == nil ? "" : "Copies \(label) to the clipboard")
    }
}

/// Label on the left, value on the right, the way System Settings lays out a
/// row. `LabeledContent`'s default style centres its parts outside a `Form`.
private struct SettingsRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            configuration.label
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            configuration.content
        }
    }
}

/// A titled group of rows, matching the grouped-form look of System Settings.
struct DetailSection<Content: View>: View {
    var title: String
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            VStack(spacing: 10) {
                content
            }
            .labeledContentStyle(SettingsRowStyle())
            .padding(14)
            .background(.background.secondary, in: .rect(cornerRadius: 10))

            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The application's Finder icon, loaded off the main thread.
struct AppIconView: View {
    var url: URL
    var size: CGFloat = 128

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.2)
                    .fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: url) {
            image = await Task.detached { BundleReader.icon(for: url) }.value
        }
    }
}

/// An expandable property-list tree, used for entitlements and the raw
/// `Info.plist`.
struct PlistTree: View {
    var entries: [String: PlistValue]
    var searchText: String = ""

    var body: some View {
        let keys = entries.keys
            .filter { matches(key: $0, value: entries[$0]) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        if keys.isEmpty {
            Text(searchText.isEmpty ? "None." : "No matches.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(keys, id: \.self) { key in
                PlistNode(key: key, value: entries[key]!)
            }
        }
    }

    private func matches(key: String, value: PlistValue?) -> Bool {
        guard !searchText.isEmpty else { return true }
        if key.localizedCaseInsensitiveContains(searchText) { return true }
        return value?.displayString.localizedCaseInsensitiveContains(searchText) ?? false
    }
}

private struct PlistNode: View {
    var key: String
    var value: PlistValue

    var body: some View {
        if value.isContainer {
            DisclosureGroup {
                switch value {
                case .dictionary(let children):
                    ForEach(children.keys.sorted(), id: \.self) { childKey in
                        PlistNode(key: childKey, value: children[childKey]!)
                    }
                case .array(let children):
                    ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                        PlistNode(key: "\(index)", value: child)
                    }
                default:
                    EmptyView()
                }
            } label: {
                row(detail: value.displayString, isSecondary: true)
            }
        } else {
            row(detail: value.displayString, isSecondary: false)
        }
    }

    private func row(detail: String, isSecondary: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.system(.callout, design: .monospaced))
            Spacer(minLength: 12)
            Text(detail)
                .font(.callout)
                .foregroundStyle(isSecondary ? .secondary : .primary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}
