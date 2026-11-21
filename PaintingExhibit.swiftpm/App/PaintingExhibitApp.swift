import SwiftUI

@main
struct PaintingExhibitApp: App {
    @StateObject private var library = Library()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            // Catch anything added to the album while the app was in the background.
            if phase == .active {
                Task { await library.processNew() }
            }
        }
    }
}
