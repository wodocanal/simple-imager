import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    private static let ejectAfterCreateKey = "ejectAfterCreate"
    private static let ejectAfterRestoreKey = "ejectAfterRestore"
    private static let autoExpandShrunkExtKey = "autoExpandShrunkExt"

    @Published var operation: OperationKind = .create
    @Published var disks: [DiskInfo] = []
    @Published var selectedDiskID: String?
    @Published var sourceDiskID: String?
    @Published var restoreSourceKind: RestoreSourceKind = .file
    @Published var remoteURLText = ""
    @Published var processingMode: ImageProcessingMode = .optimizeFreeSpace
    @Published var rawImageType: RawImageType = .img
    @Published var imageCompression: ImageCompression = .zstd
    @Published var autoExpandShrunkExt: Bool = UserDefaults.standard.object(
        forKey: AppModel.autoExpandShrunkExtKey
    ) as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoExpandShrunkExt, forKey: AppModel.autoExpandShrunkExtKey) }
    }
    @Published var ejectAfterCreate: Bool = UserDefaults.standard.object(
        forKey: AppModel.ejectAfterCreateKey
    ) as? Bool ?? false {
        didSet { UserDefaults.standard.set(ejectAfterCreate, forKey: AppModel.ejectAfterCreateKey) }
    }
    @Published var ejectAfterRestore: Bool = UserDefaults.standard.object(
        forKey: AppModel.ejectAfterRestoreKey
    ) as? Bool ?? true {
        didSet { UserDefaults.standard.set(ejectAfterRestore, forKey: AppModel.ejectAfterRestoreKey) }
    }
    @Published var outputDirectoryURL: URL?
    @Published var outputName = ""
    @Published var imageURL: URL?
    @Published var isRefreshing = false
    @Published var isWorking = false
    @Published var progress: JobProgress?
    @Published var errorMessage: String?

    private var progressURL: URL?
    private var cancelURL: URL?
    private var skipVerificationURL: URL?
    private var temporaryRemoteImageURL: URL?
    private var progressMonitor: Task<Void, Never>?

    var selectedDisk: DiskInfo? {
        disks.first { $0.identifier == selectedDiskID }
    }

    var selectedSourceDisk: DiskInfo? {
        disks.first { $0.identifier == sourceDiskID }
    }

    var availableTargetDisks: [DiskInfo] {
        guard operation == .restore, restoreSourceKind == .drive else { return disks }
        return disks.filter { $0.identifier != sourceDiskID }
    }

    var availableSourceDisks: [DiskInfo] {
        disks.filter { $0.identifier != selectedDiskID }
    }

    var canStart: Bool {
        guard selectedDisk != nil, !isWorking else { return false }
        if operation == .create {
            return outputURL != nil
                && imageCompression.isAvailable(for: .encode)
                && (!processingMode.shrinksExt || NativeExtImageShrinker.isAvailable)
        }
        switch restoreSourceKind {
        case .file:
            guard let imageURL, let format = ImageFileFormat.detect(url: imageURL) else { return false }
            return format.compression.isAvailable(for: .decode)
        case .url:
            return RemoteImageDownloader.validatedURL(from: remoteURLText) != nil
        case .drive:
            guard let source = selectedSourceDisk, let target = selectedDisk else { return false }
            return source.identifier != target.identifier && source.size <= target.size
        }
    }

    var selectedFormat: ImageFileFormat {
        ImageFileFormat(rawType: rawImageType, compression: imageCompression)
    }

    var outputURL: URL? {
        guard let outputDirectoryURL, let baseName = normalizedOutputName else { return nil }
        return outputDirectoryURL.appendingPathComponent("\(baseName).\(selectedFormat.fileSuffix)")
    }

    var codecAvailabilityMessage: String? {
        if operation == .create, processingMode.shrinksExt,
           let dependencyMessage = NativeExtImageShrinker.dependencyMessage {
            return dependencyMessage
        }
        let direction: CodecDirection = operation == .create ? .encode : .decode
        let compression: ImageCompression?
        if operation == .create {
            compression = imageCompression
        } else {
            switch restoreSourceKind {
            case .file:
                compression = imageURL.flatMap { ImageFileFormat.detect(url: $0)?.compression }
            case .url:
                compression = RemoteImageDownloader.validatedURL(from: remoteURLText)
                    .flatMap { ImageFileFormat.detect(url: URL(fileURLWithPath: $0.path))?.compression }
            case .drive:
                compression = nil
            }
        }
        guard let compression, !compression.isAvailable(for: direction) else { return nil }
        if let hint = compression.installHint {
            return "Для \(compression.title) требуется: \(hint)"
        }
        return "На этом Mac недоступен инструмент для \(compression.title)."
    }

    var needsFullDiskAccess: Bool {
        let message = errorMessage ?? progress?.message ?? ""
        return message.contains("Полный доступ к диску")
    }

    init() {
        if CommandLine.arguments.contains("--restore") {
            operation = .restore
        }
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
            if !refreshed.contains(where: { $0.identifier == sourceDiskID }) ||
                sourceDiskID == selectedDiskID {
                sourceDiskID = refreshed.first { $0.identifier != selectedDiskID }?.identifier
            }
        } catch {
            disks = []
            selectedDiskID = nil
            sourceDiskID = nil
            errorMessage = error.localizedDescription
        }
        isRefreshing = false
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Выберите папку для образа"
        panel.prompt = "Выбрать папку"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputDirectoryURL
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        outputDirectoryURL = selectedURL
        if normalizedOutputName == nil {
            outputName = defaultImageBaseName()
        }
        errorMessage = nil
        progress = nil
    }

    func updateOutputName(_ value: String) {
        outputName = value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        errorMessage = nil
        progress = nil
    }

    func chooseExistingImage() {
        let panel = NSOpenPanel()
        panel.title = "Выберите образ накопителя"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let format = ImageFileFormat.detect(url: url) else {
            errorMessage = "Поддерживаются IMG, RAW и DD без сжатия или в форматах ZSTD, GZIP, XZ, BZIP2, LZ4, ZIP и 7Z."
            progress = nil
            return
        }
        imageURL = url
        rawImageType = format.rawType
        imageCompression = format.compression
        errorMessage = nil
        progress = nil
    }

    func selectRestoreSource(_ source: RestoreSourceKind) {
        restoreSourceKind = source
        if source == .drive {
            if sourceDiskID == nil || sourceDiskID == selectedDiskID {
                sourceDiskID = availableSourceDisks.first?.identifier
            }
            if selectedDiskID == sourceDiskID {
                selectedDiskID = availableTargetDisks.first?.identifier
            }
        }
        errorMessage = nil
        progress = nil
    }

    func updateRemoteURL(_ value: String) {
        remoteURLText = value
        errorMessage = nil
        progress = nil
    }

    func selectTargetDisk(_ identifier: String) {
        selectedDiskID = identifier
        if restoreSourceKind == .drive, sourceDiskID == identifier {
            sourceDiskID = availableSourceDisks.first?.identifier
        }
        errorMessage = nil
        progress = nil
    }

    func selectSourceDisk(_ identifier: String) {
        sourceDiskID = identifier
        if selectedDiskID == identifier {
            selectedDiskID = availableTargetDisks.first?.identifier
        }
        errorMessage = nil
        progress = nil
    }

    func selectRawImageType(_ type: RawImageType) {
        rawImageType = type
        errorMessage = nil
        progress = nil
    }

    func selectImageCompression(_ compression: ImageCompression) {
        imageCompression = compression
        errorMessage = nil
        progress = nil
    }

    func start() {
        guard canStart, let disk = selectedDisk else { return }
        if operation == .create {
            startCreateImage(from: disk)
            return
        }

        switch restoreSourceKind {
        case .file:
            startFileRestore(to: disk)
        case .url:
            startRemoteRestore(to: disk)
        case .drive:
            startDriveClone(to: disk)
        }
    }

    private func startCreateImage(from disk: DiskInfo) {
        guard let outputURL else { return }
        if FileManager.default.fileExists(atPath: outputURL.path), !confirmOverwrite(at: outputURL) {
            return
        }
        guard imageCompression.isAvailable(for: .encode) else {
            errorMessage = codecAvailabilityMessage
            return
        }
        guard !processingMode.shrinksExt || NativeExtImageShrinker.isAvailable else {
            errorMessage = NativeExtImageShrinker.dependencyMessage
            return
        }

        let files = prepareJobFiles()
        var arguments = baseArguments(
            action: .create,
            disk: disk,
            format: selectedFormat,
            files: files
        )
        arguments += [
            "--output", outputURL.path,
            "--mode", processingMode.rawValue,
            "--auto-expand", String(processingMode.shrinksExt && autoExpandShrunkExt),
            "--owner", NSUserName()
        ]
        beginPrivilegedJob(arguments: arguments, files: files)
    }

    private func startFileRestore(to disk: DiskInfo) {
        guard let imageURL,
              let format = ImageFileFormat.detect(url: imageURL) else {
            errorMessage = "Не удалось определить формат выбранного образа."
            return
        }
        guard format.compression.isAvailable(for: .decode) else {
            errorMessage = codecAvailabilityMessage
            return
        }
        guard confirmDestructiveRestore(to: disk) else { return }

        let files = prepareJobFiles()
        var arguments = baseArguments(
            action: .restore,
            disk: disk,
            format: format,
            files: files
        )
        arguments += [
            "--restore-source", RestoreSourceKind.file.rawValue,
            "--input", imageURL.path,
            "--skip-verification", files.skipVerificationURL.path
        ]
        beginPrivilegedJob(arguments: arguments, files: files)
    }

    private func startDriveClone(to disk: DiskInfo) {
        guard let source = selectedSourceDisk,
              source.identifier != disk.identifier else {
            errorMessage = "Выберите разные исходный и целевой носители."
            return
        }
        guard source.size <= disk.size else {
            errorMessage = "Целевой носитель должен быть не меньше исходного."
            return
        }
        guard confirmDestructiveRestore(to: disk) else { return }

        let files = prepareJobFiles()
        var arguments = baseArguments(
            action: .restore,
            disk: disk,
            format: ImageFileFormat(rawType: .img, compression: .none),
            files: files
        )
        arguments += [
            "--restore-source", RestoreSourceKind.drive.rawValue,
            "--source-device", source.identifier,
            "--source-expected-size", String(source.size),
            "--source-expected-media-name", source.mediaName,
            "--skip-verification", files.skipVerificationURL.path
        ]
        beginPrivilegedJob(arguments: arguments, files: files)
    }

    private func startRemoteRestore(to disk: DiskInfo) {
        guard let remoteURL = RemoteImageDownloader.validatedURL(from: remoteURLText) else {
            errorMessage = "Введите прямую HTTP- или HTTPS-ссылку на файл образа."
            return
        }

        let files = prepareJobFiles()
        let downloadedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("simple-imager-\(UUID().uuidString).remote")
        temporaryRemoteImageURL = downloadedURL
        isWorking = true
        errorMessage = nil
        progress = JobProgress(
            phase: .downloading,
            processedBytes: 0,
            totalBytes: 0,
            message: "Скачиваем образ по URL…"
        )

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try RemoteImageDownloader.download(
                        from: remoteURL,
                        to: downloadedURL,
                        cancelURL: files.cancelURL
                    )
                }.value
                guard result.format.compression.isAvailable(for: .decode) else {
                    if let hint = result.format.compression.installHint {
                        throw AppError.invalidArguments(
                            "Для \(result.format.compression.title) требуется: \(hint)"
                        )
                    }
                    throw AppError.invalidArguments(
                        "На этом Mac недоступен инструмент для \(result.format.compression.title)."
                    )
                }
                try checkCancellation(at: files.cancelURL)
                guard confirmDestructiveRestore(to: disk) else {
                    throw AppError.cancelled
                }

                var arguments = baseArguments(
                    action: .restore,
                    disk: disk,
                    format: result.format,
                    files: files
                )
                arguments += [
                    "--restore-source", RestoreSourceKind.file.rawValue,
                    "--input", result.fileURL.path,
                    "--skip-verification", files.skipVerificationURL.path
                ]
                progress = JobProgress(
                    phase: .preparing,
                    processedBytes: 0,
                    totalBytes: 0,
                    message: "Ожидаем подтверждение администратора…"
                )
                beginMonitoringProgress(at: files.progressURL)
                await performPrivilegedJob(arguments: arguments, files: files)
            } catch {
                handleJobError(error, progressURL: files.progressURL)
                finishJob()
                await refreshDisks()
            }
        }
    }

    private func prepareJobFiles() -> JobFiles {
        let jobID = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
        let files = JobFiles(
            progressURL: directory.appendingPathComponent("simple-imager-\(jobID).progress.json"),
            cancelURL: directory.appendingPathComponent("simple-imager-\(jobID).cancel"),
            skipVerificationURL: directory.appendingPathComponent("simple-imager-\(jobID).skip-verification")
        )
        progressURL = files.progressURL
        cancelURL = files.cancelURL
        skipVerificationURL = files.skipVerificationURL
        for url in [files.progressURL, files.cancelURL, files.skipVerificationURL] {
            try? FileManager.default.removeItem(at: url)
        }
        return files
    }

    private func baseArguments(
        action: OperationKind,
        disk: DiskInfo,
        format: ImageFileFormat,
        files: JobFiles
    ) -> [String] {
        [
            "--action", action.rawValue,
            "--device", disk.identifier,
            "--expected-size", String(disk.size),
            "--expected-media-name", disk.mediaName,
            "--progress", files.progressURL.path,
            "--cancel", files.cancelURL.path,
            "--raw-type", format.rawType.rawValue,
            "--compression", format.compression.rawValue,
            "--eject-after", String(action == .create ? ejectAfterCreate : ejectAfterRestore)
        ]
    }

    private func beginPrivilegedJob(arguments: [String], files: JobFiles) {
        isWorking = true
        errorMessage = nil
        progress = JobProgress(
            phase: .preparing,
            processedBytes: 0,
            totalBytes: 0,
            message: "Ожидаем подтверждение администратора…"
        )
        beginMonitoringProgress(at: files.progressURL)
        Task { await performPrivilegedJob(arguments: arguments, files: files) }
    }

    private func performPrivilegedJob(arguments: [String], files: JobFiles) async {
        do {
            try await PrivilegedHelperLauncher.run(arguments: arguments)
            loadProgress(from: files.progressURL)
        } catch {
            handleJobError(error, progressURL: files.progressURL)
        }
        finishJob()
        await refreshDisks()
    }

    private func handleJobError(_ error: Error, progressURL: URL) {
        if case AppError.cancelled = error {
            progress = JobProgress(
                phase: .cancelled,
                processedBytes: 0,
                totalBytes: 0,
                message: "Операция отменена."
            )
            errorMessage = nil
            return
        }

        loadProgress(from: progressURL)
        if progress?.phase == .cancelled {
            errorMessage = nil
        } else if progress?.phase != .failed {
            errorMessage = error.localizedDescription
            progress = JobProgress(
                phase: .failed,
                processedBytes: 0,
                totalBytes: 0,
                message: error.localizedDescription
            )
        } else {
            errorMessage = progress?.message
        }
    }

    private func checkCancellation(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            throw AppError.cancelled
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

    func skipVerification() {
        guard isWorking,
              progress?.phase == .verifyingCard,
              let skipVerificationURL else { return }
        try? Data("skip".utf8).write(to: skipVerificationURL, options: .atomic)
        if let current = progress {
            progress = JobProgress(
                phase: current.phase,
                processedBytes: current.processedBytes,
                totalBytes: current.totalBytes,
                message: "Завершаем проверку по вашему запросу…"
            )
        }
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
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
        if let skipVerificationURL { try? FileManager.default.removeItem(at: skipVerificationURL) }
        if let temporaryRemoteImageURL {
            try? FileManager.default.removeItem(at: temporaryRemoteImageURL)
        }
        cancelURL = nil
        progressURL = nil
        skipVerificationURL = nil
        temporaryRemoteImageURL = nil
    }

    private var normalizedOutputName: String? {
        let value = outputName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != ".", value != ".." else { return nil }
        return value
    }

    private func defaultImageBaseName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let media = selectedDisk?.mediaName
            .replacingOccurrences(of: " ", with: "-")
            .lowercased() ?? "sd-card"
        return "\(media)-\(formatter.string(from: Date()))"
    }

    private func confirmOverwrite(at url: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Заменить существующий образ?"
        alert.informativeText = "Файл \(url.lastPathComponent) уже существует и будет полностью заменён."
        alert.addButton(withTitle: "Заменить")
        alert.addButton(withTitle: "Отмена")
        return alert.runModal() == .alertFirstButtonReturn
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

    private struct JobFiles {
        let progressURL: URL
        let cancelURL: URL
        let skipVerificationURL: URL
    }
}
