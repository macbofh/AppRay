import AppKit
import SwiftUI

/// Lets the app be a Finder "Open With" target and lets `open -a "Privilege
/// Inspector" /Applications/Safari.app` work from the command line — which is
/// how a macadmin is most likely to reach for it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: InspectorModel?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        model?.load(url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct AppRayApp: App {
    @State private var model = InspectorModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("AppRay", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 560)
                .onOpenURL { model.load($0) }
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1_000, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open App…") { model.chooseApplication() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .newItem) {
                Button("Close App") { model.reset() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(model.app == nil)

                Divider()

                Button("Export…") { model.isShowingExport = true }
                    .keyboardShortcut("e")
                    .disabled(model.app == nil)

                Button("Reveal in Finder") { model.revealInFinder() }
                    .keyboardShortcut("r")
                    .disabled(model.app == nil)
            }
            CommandGroup(after: .pasteboard) {
                Button("Copy Designated Requirement") {
                    guard let requirement = model.app?.signature.designatedRequirement else { return }
                    model.copy(requirement, label: "Designated requirement")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.app?.signature.designatedRequirement == nil)
            }
        }
    }
}
