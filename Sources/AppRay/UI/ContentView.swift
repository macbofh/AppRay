import SwiftUI

struct ContentView: View {
    @Environment(InspectorModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailView()
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.load(url)
            return true
        } isTargeted: { targeted in
            withAnimation(.snappy) { model.isDropTargeted = targeted }
        }
        .overlay {
            if model.isDropTargeted {
                DropOverlay()
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(message: toast)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $model.isShowingExport) {
            if let app = model.app {
                ExportSheet(app: app)
            }
        }
        .sheet(isPresented: $model.isShowingCollectionList) {
            CollectionListView()
        }
    }
}

// MARK: - Sidebar

/// Always present: the installed-apps browser before an app is picked, the
/// section list once one is loaded. Picking a different app from either
/// state works the same way — there is no separate "start over" screen.
private struct SidebarView: View {
    @Environment(InspectorModel.self) private var model
    @State private var localApplications: [LocalApplicationSummary] = []
    @State private var searchText = ""
    @State private var appStoreResults: [AppStoreLookupResult] = []
    @State private var isSearchingAppStore = false

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredApplications: [LocalApplicationSummary] {
        guard !searchText.isEmpty else { return localApplications }
        return localApplications.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        @Bindable var model = model

        Group {
            if let app = model.app {
                List(InspectorModel.Section.allCases, selection: $model.section) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .badge(badge(for: section, app: app))
                        .tag(section)
                }
            } else if localApplications.isEmpty {
                ProgressView("Scanning Applications…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        Button("Choose App…") { model.chooseApplication() }
                            .keyboardShortcut("o")
                    }
                    Section("Installed Apps") {
                        ForEach(filteredApplications) { app in
                            Button {
                                model.load(app.url)
                            } label: {
                                HStack(spacing: 10) {
                                    AppIconView(url: app.url, size: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name)
                                        if let bundleIdentifier = app.bundleIdentifier {
                                            Text(bundleIdentifier)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 2)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !trimmedSearchText.isEmpty {
                        Section("App Store") {
                            if isSearchingAppStore {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Searching…")
                                        .foregroundStyle(.secondary)
                                }
                            } else if appStoreResults.isEmpty {
                                Text("No matches")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(appStoreResults) { result in
                                    AppStoreResultRow(result: result) {
                                        model.selectedAppStoreResult = result
                                    } addToList: {
                                        model.add(.appStore(result: result))
                                    }
                                }
                            }
                        }
                    }
                }
                .searchable(text: $searchText, prompt: "Search installed apps or the App Store")
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 340)
        .task {
            localApplications = await LocalApplicationScanner.scan()
        }
        .task(id: searchText) {
            guard trimmedSearchText.count >= 2 else {
                appStoreResults = []
                return
            }
            // Debounce — nobody needs a lookup fired on every keystroke.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            isSearchingAppStore = true
            defer { isSearchingAppStore = false }
            appStoreResults = (try? await AppStoreLookupService.search(term: trimmedSearchText)) ?? []
        }
    }

    private func badge(for section: InspectorModel.Section, app: AnalyzedApp) -> Int {
        switch section {
        case .privileges: app.findings.count
        case .components: app.components.count
        default: 0
        }
    }
}

private struct AppStoreResultRow: View {
    var result: AppStoreLookupResult
    var select: () -> Void
    var addToList: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RemoteIconView(url: result.largestArtworkURL, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                Text("\(result.bundleIdentifier) · \(result.developerName) · \(result.platform.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add to List", systemImage: "plus.circle") {
                addToList()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Add to List")
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture {
            select()
        }
    }
}

// MARK: - Detail

private struct DetailView: View {
    @Environment(InspectorModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .loaded(let app):
                LoadedDetailView(app: app)
            case .analyzing(let url):
                AnalyzingView(url: url)
            case .failed(let message, let suggestion):
                FailureView(message: message, suggestion: suggestion)
            case .empty:
                if let result = model.selectedAppStoreResult {
                    SelectedAppStoreResultView(result: result)
                } else {
                    EmptyDetailView()
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: model.section)
    }
}

private struct LoadedDetailView: View {
    @Environment(InspectorModel.self) private var model
    var app: AnalyzedApp

    var body: some View {
        content
            .navigationTitle(app.info.name)
            .navigationSubtitle(app.info.bundleIdentifier ?? "No bundle identifier")
            .toolbar { toolbar }
    }

    @ViewBuilder
    private var content: some View {
        switch model.section {
        case .overview: OverviewView(app: app)
        case .privileges: PrivilegesView(app: app)
        case .signature: SignatureView(app: app)
        case .components: ComponentsView(app: app)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Back", systemImage: "chevron.backward") {
                model.reset()
            }
            .help("Close this app and analyse another (⇧⌘W)")
        }
        ToolbarItem(placement: .navigation) {
            AppIconView(url: app.info.url, size: 20)
                .contextMenu {
                    Button("Export Icon as PNG…") { model.exportIcon() }
                }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        ToolbarItem {
            Button("Reveal in Finder", systemImage: "folder") {
                model.revealInFinder()
            }
            .help("Reveal the bundle in Finder (⌘R)")
        }
        ToolbarItem {
            Button("Add to List", systemImage: "text.badge.plus") {
                model.add(.local(app: app))
            }
            .help("Add this app's identifiers to the collected list")
        }
        ToolbarItem {
            Button("List", systemImage: "list.bullet.rectangle.portrait") {
                model.isShowingCollectionList = true
            }
            .badge(model.collectedEntries.count)
            .help("Review the collected list and export it to CSV (⌘L)")
        }
        ToolbarItem {
            Button("Export…", systemImage: "square.and.arrow.up") {
                model.isShowingExport = true
            }
            .buttonStyle(.glassProminent)
            .help("Build a PPPC profile or DDM declaration (⌘E)")
        }
    }
}

private struct SelectedAppStoreResultView: View {
    @Environment(InspectorModel.self) private var model
    var result: AppStoreLookupResult

    var body: some View {
        AppStoreResultDetailView(result: result)
            .navigationTitle(result.name)
            .navigationSubtitle(result.bundleIdentifier)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button("Back", systemImage: "chevron.backward") {
                        model.reset()
                    }
                    .help("Back to Installed Apps (⇧⌘W)")
                }
            }
    }
}

// MARK: - Transient states

private struct EmptyDetailView: View {
    @Environment(InspectorModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Select an app", systemImage: "hand.raised.square.on.square")
        } description: {
            Text(
                """
                AppRay reads what an application can reach — usage \
                descriptions, entitlements, linked frameworks — and builds the \
                PPPC profile or DDM declaration that matches. Pick one from \
                Installed Apps, or drop a bundle from anywhere else on disk.
                """
            )
        } actions: {
            Button("List (\(model.collectedEntries.count))") { model.isShowingCollectionList = true }
                .buttonStyle(.glass)
        }
    }
}

private struct AnalyzingView: View {
    var url: URL

    var body: some View {
        VStack(spacing: 16) {
            AppIconView(url: url, size: 96)
            ProgressView()
                .controlSize(.small)
            Text("Analysing \(url.deletingPathExtension().lastPathComponent)…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailureView: View {
    @Environment(InspectorModel.self) private var model
    var message: String
    var suggestion: String?

    var body: some View {
        ContentUnavailableView {
            Label(message, systemImage: "exclamationmark.triangle")
        } description: {
            if let suggestion {
                Text(suggestion)
            }
        } actions: {
            Button("Choose App…") { model.chooseApplication() }
                .buttonStyle(.glass)
        }
    }
}

// MARK: - Overlays

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.app")
                    .font(.system(size: 44, weight: .light))
                Text("Release to analyse")
                    .font(.title3.weight(.medium))
            }
            .foregroundStyle(.tint)
            .padding(28)
            .glassEffect(in: .rect(cornerRadius: 20))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ToastView: View {
    var message: String

    var body: some View {
        Text(message)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .glassEffect(in: .capsule)
            .shadow(radius: 8, y: 2)
            .accessibilityLabel(message)
    }
}
