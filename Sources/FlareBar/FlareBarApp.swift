import AppKit
import SwiftUI

@main
struct FlareBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let iconURL = Bundle.module.url(
            forResource: "FlareBarIcon",
            withExtension: "png",
            subdirectory: "Resources"
        ) {
            NSApp.applicationIconImage = NSImage(contentsOf: iconURL)
        }
        controller = MenuBarController(model: model)
        model.start()
    }
}
