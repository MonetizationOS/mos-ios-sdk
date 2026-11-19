import SwiftUI

@main
struct ShowcaseApp: App {
    @State private var showcase = Showcase()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(showcase)
        }
    }
}
