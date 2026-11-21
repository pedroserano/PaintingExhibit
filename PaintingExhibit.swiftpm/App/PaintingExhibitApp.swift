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
                #if os(macOS)
                .frame(minWidth: 640, minHeight: 480)
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            // Catch anything added to the album while the app was in the background.
            if phase == .active {
                Task { await library.processNew() }
            }
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(library)
                .frame(width: 460)
        }
        #endif
    }
}
