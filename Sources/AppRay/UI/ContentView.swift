import SwiftUI

struct ContentView: View {
    @Environment(InspectorModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Group {
            switch model.phase {
            case .loaded(let app):
                LoadedView(app: app)
            case .analyzing(let url):
                AnalyzingView(url: url)
            case .failed(let message, let suggestion):
                FailureView(message: message, suggestion: suggestion)
            case .empty:
                EmptyStateView()
            }
        }
        .animation(.smooth(duration: 0.25), value: model.section)
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
    }
}

// MARK: - Loaded

private struct LoadedView: View {
    @Environment(InspectorModel.self) private var model
    var app: AnalyzedApp

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(InspectorModel.Section.allCases, selection: $model.section) { section in
                Label(section.title, systemImage: section.symbolName)
                    .badge(badge(for: section))
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
                .navigationTitle(app.info.name)
                .navigationSubtitle(app.info.bundleIdentifier ?? "No bundle identifier")
                .toolbar { toolbar }
        }
    }

    @ViewBuilder
    private var detail: some View {
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
            Button("Export…", systemImage: "square.and.arrow.up") {
                model.isShowingExport = true
            }
            .buttonStyle(.glassProminent)
            .help("Build a PPPC profile or DDM declaration (⌘E)")
        }
    }

    private func badge(for section: InspectorModel.Section) -> Int {
        switch section {
        case .privileges: app.findings.count
        case .components: app.components.count
        default: 0
        }
    }
}

// MARK: - Transient states

private struct EmptyStateView: View {
    @Environment(InspectorModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Drop an app here", systemImage: "hand.raised.square.on.square")
        } description: {
            Text(
                """
                AppRay reads what an application can reach — usage \
                descriptions, entitlements, linked frameworks — and builds the \
                PPPC profile or DDM declaration that matches.
                """
            )
        } actions: {
            Button("Choose App…") { model.chooseApplication() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut("o")
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
