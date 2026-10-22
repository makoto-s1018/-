import SwiftUI

@main
struct PhotoSqueezeApp: App {
    @State private var library = PhotoLibrary()
    @State private var files = FileLibrary()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(files)
        }
    }
}
