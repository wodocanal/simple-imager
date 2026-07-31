import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var operation: OperationKind = .create
    @Published var disks: [DiskInfo] = []
    @Published var selectedDiskID: String?
    @Published var captureMode: CaptureMode = .compact
    @Published var imageURL: URL?
    @Published var verifyAfterRestore = true
    @Published var isRefreshing = false
    @Published var isWorking = false
    @Published var progress: JobProgress?
    @Published var errorMessage: String?

    private var progressURL: URL?
    private var cancelURL: URL?
    private var progressMonitor: Task<Void, Never>?

    var selectedDisk: DiskInfo? {
        disks.first { $0.identifier == selectedDiskID }
    }

    var canStart: Bool {
        selectedDisk != nil && imageURL != nil && !isWorking && PrivilegedHelperLauncher.zstdPath() != nil
    }

    init() {
        Task { await refreshDisks() }
    }

    func refreshDisks() async {
        guard !isWorking else { return }
        isRefreshing = true
        errorMessage = nil
        do {
            let refreshed = try await Task.detached(priority: .userInitiated) {
                try DiskService.listExternalPhysicalDisks()
            }.value
            disks = refreshed
            if !refreshed.contains(where: { $0.identifier == selectedDiskID }) {
                selectedDiskID = refreshed.first?.identifier
            }
        } catch {
            disks = []
            selectedDiskID = nil
            errorMessage = error.localizedDescription
        }
        isRefreshing = false
    }

    func chooseImageLocation() {
        let panel = NSSavePanel()
        panel.title = "Куда сохранить образ SD-карты"
        panel.nameFieldStringValue = defaultImageName()
        panel.canCreateDirectories = true
        if let zstdType = UTType(filenameExtension: "zst") {
            panel.allowedContentTypes = [zstdType]
        }
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if !url.lastPathComponent.hasSuffix(".sdimg.zst") {
            let base = url.deletingPathExtension().lastPathComponent
            url = url.deletingLastPathComponent().appendingPathComponent("\(base).sdimg.zst")
        }
        imageURL = url
        errorMessage = nil
        progress = nil
    }

    func chooseExistingImage() {
        let panel = NSOpenPanel()
        panel.title = "Выберите сжатый образ SD-карты"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let zstdType = UTType(filenameExtension: "zst") {
            panel.allowedContentTypes = [zstdType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        imageURL = url
        errorMessage = nil
        progress = nil
    }

    func start() {
        guard canStart, let disk = selectedDisk, let imageURL else { return }
        if operation == .restore, !confirmDestructiveRestore(to: disk) { return }

        guard let zstd = PrivilegedHelperLauncher.zstdPath() else {
            errorMessage = "Для работы нужен zstd. Установите его командой: brew install zstd"
            return
        }

        let jobID = UUID().uuidString
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let progressURL = temporaryDirectory.appendingPathComponent("sd-card-copy-\(jobID).progress.json")
        let cancelURL = temporaryDirectory.appendingPathComponent("sd-card-copy-\(jobID).cancel")
        self.progressURL = progressURL
        self.cancelURL = cancelURL
        try? FileManager.default.removeItem(at: progressURL)
        try? FileManager.default.removeItem(at: cancelURL)

        var arguments = [
            "--action", operation.rawValue,
            "--device", disk.identifier,
            "--progress", progressURL.path,
            "--cancel", cancelURL.path,
            "--zstd", zstd
        ]
        if operation == .create {
            arguments += [
                "--output", imageURL.path,
                "--mode", captureMode.rawValue,
                "--owner", NSUserName()
            ]
        } else {
            arguments += [
                "--input", imageURL.path,
                "--verify", verifyAfterRestore ? "true" : "false"
            ]
        }

        isWorking = true
        errorMessage = nil
        progress = JobProgress(phase: .preparing, processedBytes: 0, totalBytes: 0, message: "Ожидаем подтверждение администратора…")
        beginMonitoringProgress(at: progressURL)

        Task {
            do {
                try await PrivilegedHelperLauncher.run(arguments: arguments)
                loadProgress(from: progressURL)
            } catch AppError.cancelled {
                progress = JobProgress(phase: .cancelled, processedBytes: 0, totalBytes: 0, message: "Операция отменена.")
            } catch {
                loadProgress(from: progressURL)
                if progress?.phase == .cancelled {
                    errorMessage = nil
                } else if progress?.phase != .failed {
                    errorMessage = error.localizedDescription
                    progress = JobProgress(phase: .failed, processedBytes: 0, totalBytes: 0, message: error.localizedDescription)
                } else {
                    errorMessage = progress?.message
                }
            }
            finishJob()
            await refreshDisks()
        }
    }

    func cancel() {
        guard isWorking, let cancelURL else { return }
        try? Data("cancel".utf8).write(to: cancelURL, options: .atomic)
        if let current = progress {
            progress = JobProgress(
                phase: current.phase,
                processedBytes: current.processedBytes,
                totalBytes: current.totalBytes,
                message: "Запрошена отмена. Завершаем текущий блок…"
            )
        }
    }

    private func beginMonitoringProgress(at url: URL) {
        progressMonitor?.cancel()
        progressMonitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.loadProgress(from: url)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func loadProgress(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(JobProgress.self, from: data) else { return }
        progress = value
        if value.phase == .failed { errorMessage = value.message }
    }

    private func finishJob() {
        progressMonitor?.cancel()
        progressMonitor = nil
        isWorking = false
        if let cancelURL { try? FileManager.default.removeItem(at: cancelURL) }
        if let progressURL { try? FileManager.default.removeItem(at: progressURL) }
        cancelURL = nil
        progressURL = nil
    }

    private func defaultImageName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let media = selectedDisk?.mediaName
            .replacingOccurrences(of: " ", with: "-")
            .lowercased() ?? "sd-card"
        return "\(media)-\(formatter.string(from: Date())).sdimg.zst"
    }

    private func confirmDestructiveRestore(to disk: DiskInfo) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Стереть все данные на \(disk.mediaName)?"
        alert.informativeText = "Будет полностью перезаписан диск \(disk.devicePath) размером \(ByteCountFormatter.string(fromByteCount: Int64(disk.size), countStyle: .decimal)). Отменить запись после ее начала без повреждения данных нельзя."
        alert.addButton(withTitle: "Стереть и записать")
        alert.addButton(withTitle: "Отмена")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
