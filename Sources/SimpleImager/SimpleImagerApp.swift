import AppKit
import SwiftUI

@main
struct SimpleImagerApp: App {
    init() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--helper" {
            let status = ImagingHelper.run(arguments: Array(arguments.dropFirst()))
            exit(status)
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(width: 720, height: 495)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentSize)
    }
}
