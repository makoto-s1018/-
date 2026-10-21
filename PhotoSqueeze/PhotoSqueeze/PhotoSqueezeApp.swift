import SwiftUI

@main
struct PhotoSqueezeApp: App {
    @State private var library = PhotoLibrary()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
        }
    }
}
