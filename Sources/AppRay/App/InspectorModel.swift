import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class InspectorModel {
    enum Phase {
        case empty
        case analyzing(URL)
        case loaded(AnalyzedApp)
        case failed(message: String, suggestion: String?)
    }

    enum Section: String, CaseIterable, Identifiable {
        case overview
        case privileges
        case signature
        case components

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: "Overview"
            case .privileges: "Privileges"
            case .signature: "Signature"
            case .components: "Components"
            }
        }

        var symbolName: String {
            switch self {
            case .overview: "info.circle"
            case .privileges: "hand.raised"
            case .signature: "signature"
            case .components: "shippingbox"
            }
        }
    }

    private(set) var phase: Phase = .empty
    var isDropTargeted = false
    var section: Section = .overview
    var selectedFinding: PrivilegeFinding.ID?
    var isShowingExport = false
    private(set) var toast: String?

    private var toastTask: Task<Void, Never>?

    var app: AnalyzedApp? {
        if case .loaded(let app) = phase { return app }
        return nil
    }

    var isBusy: Bool {
        if case .analyzing = phase { return true }
        return false
    }

    func load(_ url: URL) {
        // Resolve aliases and symlinks so dropping an alias from the Dock or a
        // symlinked /Applications entry analyses the real bundle.
        let resolved = (try? URL(resolvingAliasFileAt: url)) ?? url.resolvingSymlinksInPath()
        phase = .analyzing(resolved)
        selectedFinding = nil
        section = .overview

        Task {
            do {
                let app = try await AppAnalyzer.analyze(url: resolved)
                phase = .loaded(app)
                NSDocumentController.shared.noteNewRecentDocumentURL(resolved)

                // Verification takes seconds on a large bundle, so it lands
                // afterwards and the badges fill themselves in.
                let trust = await AppAnalyzer.assessTrust(url: resolved)
                guard case .loaded(var current) = phase, current.info.url == resolved else { return }
                current.trust = trust
                withAnimation(.smooth) { phase = .loaded(current) }
            } catch {
                let error = error as? AnalysisError
                phase = .failed(
                    message: error?.errorDescription ?? "Could not analyse that bundle.",
                    suggestion: error?.recoverySuggestion
                )
            }
        }
    }

    func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Analyse"
        panel.message = "Choose an application to inspect."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func reset() {
        phase = .empty
        selectedFinding = nil
    }

    func revealInFinder() {
        guard let url = app?.info.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Saves the analysed app's icon as a PNG at the largest size Icon
    /// Services provides.
    func exportIcon() {
        guard let app else { return }
        let panel = NSSavePanel()
        let cleaned = app.info.name.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(cleaned)-icon.png"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        guard let data = BundleReader.largestIconPNG(for: app.info.url) else {
            show(toast: "Could not render the icon")
            return
        }
        do {
            try data.write(to: destination)
            show(toast: "Saved \(destination.lastPathComponent)")
        } catch {
            show(toast: "Could not save: \(error.localizedDescription)")
        }
    }

    func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(toast: "\(label) copied")
    }

    func show(toast message: String) {
        toastTask?.cancel()
        withAnimation(.snappy) { toast = message }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { toast = nil }
        }
    }

    // MARK: - Export

    func write(_ data: Data, channel: ExportChannel, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).\(channel.fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: channel.fileExtension) ?? .data,
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            show(toast: "Saved \(url.lastPathComponent)")
        } catch {
            show(toast: "Could not save: \(error.localizedDescription)")
        }
    }

    /// A filename stem like `Safari-pppc`, safe for the filesystem.
    func suggestedFilename(for channel: ExportChannel) -> String {
        let base = app?.info.name ?? "App"
        let cleaned = base.replacingOccurrences(of: "/", with: "-")
        return "\(cleaned)-\(channel == .pppc ? "pppc" : "ddm")"
    }
}
