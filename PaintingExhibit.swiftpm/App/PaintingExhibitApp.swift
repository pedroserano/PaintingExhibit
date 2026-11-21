import SwiftUI

@main
struct PaintingExhibitApp: App {
    @StateObject private var library = Library()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
        }
    }
}
