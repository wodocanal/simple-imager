import AppKit
import SwiftUI

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var isWaitingForCancellation = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isWorking else { return .terminateNow }
        guard !isWaitingForCancellation else { return .terminateLater }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.choose(
            english: "An operation is still running",
            russian: "Операция ещё выполняется"
        )
        alert.informativeText = L10n.choose(
            english: "Closing Simple Imager will safely stop the current operation. If data is being written, the target drive may need to be flashed again.",
            russian: "При закрытии Simple Imager текущая операция будет безопасно остановлена. Если данные записываются, целевой накопитель потребуется прошить заново."
        )
        alert.addButton(withTitle: L10n.choose(english: "Stop and Quit", russian: "Остановить и выйти"))
        alert.addButton(withTitle: L10n.choose(english: "Keep Working", russian: "Продолжить работу"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        isWaitingForCancellation = true
        model.prepareForTermination()
        Task { @MainActor [weak self, weak model] in
            while model?.isWorking == true {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            self?.isWaitingForCancellation = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct SimpleImagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--helper" {
            let status = ImagingHelper.run(arguments: Array(arguments.dropFirst()))
            exit(status)
        }
        _model = StateObject(wrappedValue: AppModel())
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(width: 720, height: 415)
                .onAppear { appDelegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentSize)
    }
}
