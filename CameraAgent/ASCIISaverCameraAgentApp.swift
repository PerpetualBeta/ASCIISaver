import SwiftUI

@main
struct ASCIISaverCameraAgentApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No WindowGroup => no “Hello world” window.
        // Keep an empty Settings scene so the app conforms cleanly.
        Settings {
            EmptyView()
        }
    }
}
