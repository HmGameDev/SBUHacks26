import SwiftUI

@main
struct WayfinderApp: App {
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Refresh Siri's copy of the phrases on every launch, so new ones work without reinstalling.
        WayfinderShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            // ARKit stops in the background, so say so instead of going silent.
            if phase == .background {
                model.stop(announce: true)
            }
        }
    }
}
