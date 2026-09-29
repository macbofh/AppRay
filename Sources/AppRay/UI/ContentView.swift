import SwiftUI

struct ContentView: View {
    @Environment(InspectorModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $model.columnVisibility) {
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
/// Owns the search state and carries `.searchable` — `isSearching` and
/// `dismissSearch` only exist for views *below* whatever declares that
/// modifier, so the list that reacts to them has to be a child of this one,
/// not this same view.
private struct SidebarView: View {
    @State private var localApplications: [LocalApplicationSummary] = []
    @State private var searchText = ""
    @State private var appStoreResults: [AppStoreLookupResult] = []
    @State private var isSearchingAppStore = false

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SidebarList(
            localApplications: localApplications,
            searchText: searchText,
            appStoreResults: appStoreResults,
            isSearchingAppStore: isSearchingAppStore
        )
        .searchable(text: $searchText, prompt: "Search installed apps or the App Store")
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
}

private struct SidebarList: View {
    @Environment(InspectorModel.self) private var model
    @Environment(\.isSearching) private var isSearching
    // `dismissSearch()` ends the search interaction on macOS by clearing the
    // field along with it, which is exactly the query this screen is meant to
    // preserve. This flag switches the list back to the loaded app's sections
    // without touching the search text at all.
    @State private var isBrowsingSearch = false

    var localApplications: [LocalApplicationSummary]
    var searchText: String
    var appStoreResults: [AppStoreLookupResult]
    var isSearchingAppStore: Bool

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
            if let app = model.app, !isBrowsingSearch {
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
                    Section("Installed Apps") {
                        ForEach(filteredApplications) { app in
                            LocalApplicationRow(
                                app: app,
                                isFavorite: model.isFavorite(.local(summary: app))
                            ) {
                                isBrowsingSearch = false
                                model.load(app.url)
                            } toggleFavorite: {
                                model.toggleFavorite(.local(summary: app))
                            }
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
                                    AppStoreResultRow(
                                        result: result,
                                        isFavorite: model.isFavorite(.appStore(result: result))
                                    ) {
                                        isBrowsingSearch = false
                                        model.selectedAppStoreResult = result
                                    } toggleFavorite: {
                                        model.toggleFavorite(.appStore(result: result))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: isSearching) { _, isSearching in
            if isSearching {
                isBrowsingSearch = true
                // A search that starts behind a hidden sidebar has nowhere to
                // show its results.
                model.columnVisibility = .all
            }
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
    var isFavorite: Bool
    var select: () -> Void
    var toggleFavorite: () -> Void

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
            FavoriteButton(isFavorite: isFavorite, action: toggleFavorite)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture {
            select()
        }
    }
}

private struct LocalApplicationRow: View {
    var app: LocalApplicationSummary
    var isFavorite: Bool
    var select: () -> Void
    var toggleFavorite: () -> Void

    var body: some View {
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
            FavoriteButton(isFavorite: isFavorite, action: toggleFavorite)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
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
        ToolbarSpacer(.flexible)
        ToolbarItem {
            Button("Reveal in Finder", systemImage: "finder") {
                model.revealInFinder()
            }
            .help("Reveal the bundle in Finder (⌘R)")
        }
        ToolbarItem {
            FavoriteButton(isFavorite: model.isFavorite(.local(app: app))) {
                model.toggleFavorite(.local(app: app))
            }
        }
        if !model.collectedEntries.isEmpty {
            ToolbarItem {
                FavoritesListButton(count: model.collectedEntries.count) {
                    model.isShowingCollectionList = true
                }
            }
        }
        ToolbarItem {
            Button("Export…", systemImage: "square.and.arrow.up") {
                model.isShowingExport = true
            }
            .help("Build a PPPC profile or DDM declaration (⌘E)")
        }
    }
}

private struct SelectedAppStoreResultView: View {
    @Environment(InspectorModel.self) private var model
    var result: AppStoreLookupResult

    var body: some View {
        AppStoreResultDetailView(result: result)
            .toolbar { toolbar }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Back", systemImage: "chevron.backward") {
                model.reset()
            }
            .help("Back to Installed Apps (⇧⌘W)")
        }
        ToolbarSpacer(.flexible)
        ToolbarItem {
            FavoriteButton(isFavorite: model.isFavorite(.appStore(result: result))) {
                model.toggleFavorite(.appStore(result: result))
            }
        }
        if !model.collectedEntries.isEmpty {
            ToolbarItem {
                FavoritesListButton(count: model.collectedEntries.count) {
                    model.isShowingCollectionList = true
                }
            }
        }
    }
}

// MARK: - Transient states

private struct EmptyDetailView: View {
    @Environment(InspectorModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 20) {
                Image("AppRay")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Drag & Drop")
                        .font(.title2.weight(.semibold))
                    Text(
                        """
                        AppRay reads what an application can reach — usage \
                        descriptions, entitlements, linked frameworks — and builds the \
                        PPPC profile or DDM declaration that matches. Drop a bundle \
                        anywhere in this window, or pick one from Installed Apps.
                        """
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                }
            }
            .padding(40)
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.tertiary, style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
            }

            Button("Choose App…") { model.chooseApplication() }
                .keyboardShortcut("o")
                .buttonStyle(.glassProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            if !model.collectedEntries.isEmpty {
                ToolbarItem {
                    FavoritesListButton(count: model.collectedEntries.count) {
                        model.isShowingCollectionList = true
                    }
                }
            }
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
