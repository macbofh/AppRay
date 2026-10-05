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
    /// Starts hidden — revealed the moment a search begins, since search
    /// results have nowhere else to render.
    var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    var section: Section = .overview
    var selectedFinding: PrivilegeFinding.ID?
    var isShowingExport = false
    var isShowingCollectionList = false
    var selectedAppStoreResult: AppStoreLookupResult?
    private(set) var collectedEntries: [CollectedEntry] = []
    private(set) var isExportingCSV = false
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
        selectedAppStoreResult = nil
        section = .overview

        Task {
            do {
                let app = try await AppAnalyzer.analyze(url: resolved)
                phase = .loaded(app)
                NSDocumentController.shared.noteNewRecentDocumentURL(resolved)
                // Upgrades a favorite added from the sidebar's quick heart —
                // before this app was ever analysed — to the full row now
                // that there is one to build it from.
                refreshFavoriteIfPresent(.local(app: app))

                // Verification takes seconds on a large bundle, so it lands
                // afterwards and the badges fill themselves in.
                let trust = await AppAnalyzer.assessTrust(layout: app.info.layout)
                guard case .loaded(var current) = phase, current.info.url == resolved else { return }
                current.trust = trust
                withAnimation(.smooth) { phase = .loaded(current) }
                // A favorite added in the gap before trust landed would
                // otherwise be stuck without notarization/Gatekeeper facts.
                refreshFavoriteIfPresent(.local(app: current))
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
        selectedAppStoreResult = nil
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

    /// Saves an App Store icon — downloaded from Apple's catalog, since
    /// there is no local bundle to render one from.
    func exportRemoteIcon(from url: URL, suggestedName: String) {
        let cleaned = suggestedName.replacingOccurrences(of: "/", with: "-")
        let fileExtension = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(cleaned)-icon.\(fileExtension)"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .png]
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                try data.write(to: destination)
                show(toast: "Saved \(destination.lastPathComponent)")
            } catch {
                show(toast: "Could not save: \(error.localizedDescription)")
            }
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

    // MARK: - Favorites

    func isFavorite(_ entry: CollectedEntry) -> Bool {
        collectedEntries.contains(where: { $0.id == entry.id })
    }

    func add(_ entry: CollectedEntry) {
        guard !collectedEntries.contains(where: { $0.id == entry.id }) else {
            show(toast: "Already in Favorites")
            return
        }
        collectedEntries.append(entry)
        show(toast: "Added to Favorites")
    }

    func remove(_ entry: CollectedEntry) {
        collectedEntries.removeAll { $0.id == entry.id }
    }

    func toggleFavorite(_ entry: CollectedEntry) {
        if isFavorite(entry) {
            remove(entry)
        } else {
            add(entry)
        }
    }

    /// Replaces an already-favorited entry with a fresher one carrying the
    /// same identity — silently, since this is a background upgrade, not
    /// something the admin asked for right now. Does nothing if the app was
    /// never favorited, so it is safe to call on every analysis completion.
    func refreshFavoriteIfPresent(_ entry: CollectedEntry) {
        guard let index = collectedEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        collectedEntries[index] = entry
    }

    /// Jumps from a favorites row back to that app's details — reanalysing
    /// a local bundle from its URL, or reselecting the original App Store
    /// lookup, since neither is cached anywhere else.
    func open(_ entry: CollectedEntry) {
        switch entry.source {
        case .localAnalysis:
            guard let url = entry.localURL else { return }
            load(url)
        case .appStoreLookup:
            guard let result = entry.appStoreResult else { return }
            reset()
            selectedAppStoreResult = result
        }
        isShowingCollectionList = false
    }

    func exportCollectedEntriesAsCSV() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AppRay-favorites.csv"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExportingCSV = true
        let failures = await enrichEntriesNeedingAnalysis()
        isExportingCSV = false

        do {
            try CSVExportBuilder.build(entries: collectedEntries).write(to: url, atomically: true, encoding: .utf8)
            show(toast: failures == 0
                ? "Saved \(url.lastPathComponent)"
                : "Saved \(url.lastPathComponent) — \(failures) app\(failures == 1 ? "" : "s") could not be re-analysed")
        } catch {
            show(toast: "Could not save: \(error.localizedDescription)")
        }
    }

    /// A favorite added straight from the sidebar's quick heart carries only
    /// a name and a path until something opens it — this is what guarantees
    /// the CSV never ships that half-empty row. Only ever touches entries
    /// still missing analysis, so exporting a list of already-opened
    /// favorites costs nothing extra.
    private func enrichEntriesNeedingAnalysis() async -> Int {
        let sparse = collectedEntries.filter { $0.source == .localAnalysis && !$0.isFullyAnalyzed }
        guard !sparse.isEmpty else { return 0 }

        var failures = 0
        await withTaskGroup(of: CollectedEntry?.self) { group in
            for entry in sparse {
                guard let url = entry.localURL else { continue }
                group.addTask {
                    guard let app = try? await AppAnalyzer.analyze(url: url) else { return nil }
                    var enriched = app
                    enriched.trust = await AppAnalyzer.assessTrust(layout: app.info.layout)
                    return .local(app: enriched)
                }
            }
            for await result in group {
                if let result {
                    refreshFavoriteIfPresent(result)
                } else {
                    failures += 1
                }
            }
        }
        return failures
    }
}
