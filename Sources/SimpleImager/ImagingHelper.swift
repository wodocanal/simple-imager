import CryptoKit
import Darwin
import Foundation

enum ImagingHelper {
    private static let chunkSize = 4 * 1024 * 1024
    private static let deviceOpenTimeout: TimeInterval = 60
    private static let deviceRetryDelay: TimeInterval = 0.5

    static func run(arguments: [String]) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Создание или восстановление образа накопителя"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        _ = setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_IMPORTANT)

        do {
            guard geteuid() == 0 else {
                throw AppError.unsafeDisk("Для доступа к карте требуются права администратора.")
            }
            let values = try parse(arguments: arguments)
            guard let action = values["action"],
                  let device = values["device"],
                  let expectedSizeValue = values["expected-size"],
                  let expectedSize = UInt64(expectedSizeValue),
                  let expectedMediaName = values["expected-media-name"],
                  let progressPath = values["progress"],
                  let cancelPath = values["cancel"],
                  let rawTypeValue = values["raw-type"],
                  let rawType = RawImageType(rawValue: rawTypeValue),
                  let compressionValue = values["compression"],
                  let compression = ImageCompression(rawValue: compressionValue) else {
                throw AppError.invalidArguments("Не хватает аргументов helper-процесса.")
            }
            let format = ImageFileFormat(rawType: rawType, compression: compression)
            let ejectAfter = values["eject-after"] == "true"

            let reporter = ProgressReporter(
                progressURL: URL(fileURLWithPath: progressPath),
                cancelURL: URL(fileURLWithPath: cancelPath),
                skipVerificationURL: values["skip-verification"].map(URL.init(fileURLWithPath:))
            )
            let expectedDisk = ExpectedDisk(
                identifier: device,
                mediaName: expectedMediaName,
                size: expectedSize
            )

            switch action {
            case "create":
                guard let output = values["output"],
                      let modeValue = values["mode"],
                      let mode = ImageProcessingMode(rawValue: modeValue) else {
                    throw AppError.invalidArguments("Не указаны параметры создания образа.")
                }
                try createImage(
                    expectedDisk: expectedDisk,
                    outputURL: URL(fileURLWithPath: output),
                    mode: mode,
                    format: format,
                    autoExpand: values["auto-expand"] == "true",
                    ejectAfter: ejectAfter,
                    owner: values["owner"],
                    reporter: reporter
                )
            case "restore":
                let restoreSource = RestoreSourceKind(
                    rawValue: values["restore-source"] ?? RestoreSourceKind.file.rawValue
                )
                switch restoreSource {
                case .file:
                    guard let input = values["input"] else {
                        throw AppError.invalidArguments("Не указан файл образа.")
                    }
                    try restoreImage(
                        expectedDisk: expectedDisk,
                        inputURL: URL(fileURLWithPath: input),
                        format: format,
                        ejectAfter: ejectAfter,
                        reporter: reporter
                    )
                case .drive:
                    guard let sourceDevice = values["source-device"],
                          let sourceSizeValue = values["source-expected-size"],
                          let sourceSize = UInt64(sourceSizeValue),
                          let sourceMediaName = values["source-expected-media-name"] else {
                        throw AppError.invalidArguments("Не указан исходный носитель для клонирования.")
                    }
                    try cloneDisk(
                        source: ExpectedDisk(
                            identifier: sourceDevice,
                            mediaName: sourceMediaName,
                            size: sourceSize
                        ),
                        target: expectedDisk,
                        ejectAfter: ejectAfter,
                        reporter: reporter
                    )
                case .url, .none:
                    throw AppError.invalidArguments("Неизвестный источник образа.")
                }
            default:
                throw AppError.invalidArguments("Неизвестная операция helper-процесса.")
            }
            return 0
        } catch AppError.cancelled {
            writeTerminalProgress(arguments: arguments, phase: .cancelled, message: "Операция отменена. Носитель может содержать незавершенные данные.")
            fputs("Операция отменена.\n", stderr)
            return 2
        } catch {
            writeTerminalProgress(arguments: arguments, phase: .failed, message: error.localizedDescription)
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func createImage(
        expectedDisk: ExpectedDisk,
        outputURL: URL,
        mode: ImageProcessingMode,
        format: ImageFileFormat,
        autoExpand: Bool,
        ejectAfter: Bool,
        owner: String?,
        reporter: ProgressReporter
    ) throws {
        if mode.shrinksExt, let dependencyMessage = NativeExtImageShrinker.dependencyMessage {
            throw AppError.invalidArguments(dependencyMessage)
        }
        reporter.update(phase: .preparing, processed: 0, total: 0, message: "Проверяем карту…", force: true)
        let disk = try waitForExpectedDisk(expectedDisk, reporter: reporter)
        try reporter.checkCancellation()
        try ensureDestinationIsNot(on: disk, outputURL: outputURL)

        let parent = outputURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppError.invalidArguments("Папка для образа не существует.")
        }

        var shouldMountDisk = true
        defer {
            if shouldMountDisk { DiskService.mount(disk) }
        }

        let source = try openExpectedDisk(expectedDisk, forWriting: false, reporter: reporter)
        var sourceIsOpen = true
        defer {
            if sourceIsOpen { try? source.close() }
        }

        let shrinkPlan: ExtShrinkPlan?
        if mode.shrinksExt {
            reporter.update(
                phase: .analyzing,
                processed: 0,
                total: disk.size,
                message: "Проверяем возможность уменьшения ext-раздела…",
                force: true
            )
            shrinkPlan = try NativeExtImageShrinker.analyze(handle: source, diskSize: disk.size)
        } else {
            shrinkPlan = nil
        }

        var compactPlan = CompactPlan(regions: [], rawPartitions: [])
        if mode.optimizesFreeSpace {
            reporter.update(phase: .analyzing, processed: 0, total: disk.size, message: "Ищем свободные кластеры FAT32/exFAT…", force: true)
            compactPlan = CompactImageAnalyzer.buildPlan(handle: source, diskSize: disk.size)
        }
        try source.seek(toOffset: 0)

        let identifier = UUID().uuidString
        let captureURL = mode.shrinksExt
            ? parent.appendingPathComponent(".partial-\(identifier)-source.raw")
            : parent.appendingPathComponent(".partial-\(identifier)-\(outputURL.lastPathComponent)")
        let encodedURL = parent.appendingPathComponent(".partial-encoded-\(identifier)-\(outputURL.lastPathComponent)")
        try? FileManager.default.removeItem(at: captureURL)
        try? FileManager.default.removeItem(at: encodedURL)
        defer {
            try? FileManager.default.removeItem(at: captureURL)
            try? FileManager.default.removeItem(at: encodedURL)
        }

        let captureCompression: ImageCompression = mode.shrinksExt ? .none : format.compression

        let encoder = try ImageEncoder(
            compression: captureCompression,
            outputURL: captureURL,
            archiveEntryName: format.archiveEntryName,
            sparse: mode.shrinksExt || (mode.optimizesFreeSpace && format.compression == .none)
        )

        var processed: UInt64 = 0
        do {
            while processed < disk.size {
                try reporter.checkCancellation()
                let amount = min(chunkSize, Int(disk.size - processed))
                var data = try PosixIO.readBlock(from: source, count: amount)
                guard !data.isEmpty else {
                    throw AppError.commandFailed("Карта закончилась раньше ожидаемого размера.")
                }
                if mode.optimizesFreeSpace {
                    compactPlan.sanitize(&data, at: processed)
                }
                try encoder.write(data)
                processed += UInt64(data.count)
                reporter.update(
                    phase: .reading,
                    processed: processed,
                    total: disk.size,
                    message: mode.shrinksExt
                        ? "Читаем карту во временный образ…"
                        : (format.compression == .none
                            ? (mode.optimizesFreeSpace
                                ? "Читаем карту и создаём разреженный образ…"
                                : "Читаем карту и сохраняем образ…")
                            : "Читаем карту и сжимаем образ…")
                )
            }
            try encoder.finish()
        } catch {
            encoder.cancel()
            throw error
        }

        try source.close()
        sourceIsOpen = false
        DiskService.mount(disk)

        let logicalSize: UInt64
        var autoExpandStatus = ExtAutoExpandStatus.notRequested
        let completedTemporaryURL: URL
        if let shrinkPlan {
            let shrinkResult = try NativeExtImageShrinker.shrink(
                imageURL: captureURL,
                plan: shrinkPlan,
                autoExpand: autoExpand,
                reporter: reporter
            )
            logicalSize = shrinkResult.logicalSize
            autoExpandStatus = shrinkResult.autoExpandStatus
            if format.compression == .none {
                completedTemporaryURL = captureURL
            } else {
                try compressRawImage(
                    inputURL: captureURL,
                    outputURL: encodedURL,
                    logicalSize: logicalSize,
                    format: format,
                    reporter: reporter
                )
                completedTemporaryURL = encodedURL
            }
        } else {
            logicalSize = disk.size
            completedTemporaryURL = captureURL
        }

        reporter.update(phase: .finalizing, processed: logicalSize, total: logicalSize, message: "Сохраняем образ…", force: true)
        try replaceItem(at: outputURL, with: completedTemporaryURL)
        try setOwnership(paths: [outputURL.path], owner: owner)

        var detail: String
        if mode.shrinksExt {
            detail = "Образ уменьшен с \(formattedSize(disk.size)) до \(formattedSize(logicalSize)) и сохранён как .\(format.fileSuffix)."
            switch autoExpandStatus {
            case .installed:
                detail += " Авторасширение ext при первой загрузке включено."
            case .systemdUnavailable:
                detail += " Авторасширение не добавлено: в образе не найден systemd."
            case .notRequested:
                break
            }
        } else if compactPlan.compactedFileSystems.isEmpty && mode.optimizesFreeSpace {
            detail = "Образ создан. Поддерживаемые FAT32/exFAT-разделы не найдены, данные сохранены полностью."
        } else if mode.optimizesFreeSpace,
                  format.compression == .none,
                  let allocatedSize = allocatedFileSize(at: outputURL) {
            detail = "Разреженный образ создан: логически \(formattedSize(disk.size)), на диске \(formattedSize(allocatedSize))."
        } else {
            detail = "Образ сохранён в формате .\(format.fileSuffix)."
        }
        let ejection = ejectIfRequested(disk, requested: ejectAfter)
        shouldMountDisk = !ejection.ejected
        detail += ejection.messageSuffix
        reporter.update(phase: .completed, processed: logicalSize, total: logicalSize, message: detail, force: true)
    }

    private static func compressRawImage(
        inputURL: URL,
        outputURL: URL,
        logicalSize: UInt64,
        format: ImageFileFormat,
        reporter: ProgressReporter
    ) throws {
        let source = try FileHandle(forReadingFrom: inputURL)
        defer { try? source.close() }
        let encoder = try ImageEncoder(
            compression: format.compression,
            outputURL: outputURL,
            archiveEntryName: format.archiveEntryName,
            sparse: false
        )

        var processed: UInt64 = 0
        do {
            while processed < logicalSize {
                try reporter.checkCancellation()
                let amount = min(chunkSize, Int(logicalSize - processed))
                let data = try PosixIO.readBlock(from: source, count: amount)
                guard !data.isEmpty else {
                    throw AppError.commandFailed("Уменьшенный образ закончился раньше ожидаемого размера.")
                }
                try encoder.write(data)
                processed += UInt64(data.count)
                reporter.update(
                    phase: .finalizing,
                    processed: processed,
                    total: logicalSize,
                    message: "Сжимаем уменьшенный образ…"
                )
            }
            try encoder.finish()
        } catch {
            encoder.cancel()
            throw error
        }
    }

    private static func restoreImage(
        expectedDisk: ExpectedDisk,
        inputURL: URL,
        format: ImageFileFormat,
        ejectAfter: Bool,
        reporter: ProgressReporter
    ) throws {
        reporter.update(phase: .preparing, processed: 0, total: 0, message: "Проверяем образ и целевую карту…", force: true)
        let disk = try waitForExpectedDisk(expectedDisk, reporter: reporter)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw AppError.archiveInvalid("Выбранный файл образа не существует.")
        }

        try reporter.checkCancellation()
        let inspection = try inspectImage(
            inputURL: inputURL,
            format: format,
            reporter: reporter
        )
        guard inspection.size > 0 else {
            throw AppError.archiveInvalid("Образ не содержит данных.")
        }
        guard inspection.size <= disk.size else {
            throw AppError.archiveInvalid(
                "Целевой накопитель меньше образа: нужно минимум \(ByteCountFormatter.string(fromByteCount: Int64(inspection.size), countStyle: .decimal))."
            )
        }

        try reporter.checkCancellation()
        var shouldMountDisk = true
        defer {
            if shouldMountDisk { DiskService.mount(disk) }
        }

        // Keep one read/write descriptor open through verification. Closing it between
        // writing and reading gives Disk Arbitration a chance to mount and mutate data.
        let target = try openExpectedDisk(expectedDisk, forWriting: true, reporter: reporter)
        do {
            try clearTrailingSignatures(target: target, targetSize: disk.size)
            let writtenDigest = try writeDecompressedImage(
                inputURL: inputURL,
                target: target,
                expectedSize: inspection.size,
                format: format,
                reporter: reporter
            )
            guard writtenDigest == inspection.sha256 else {
                throw AppError.archiveInvalid("Файл образа изменился после предварительной проверки.")
            }
            try target.synchronize()
            let verification = try WrittenMediaVerifier.verify(
                handle: target,
                totalSize: inspection.size,
                expectedSHA256: inspection.sha256,
                reporter: reporter,
                message: "Сверяем записанный накопитель…",
                prematureReadMessage: "Контрольное чтение завершилось преждевременно.",
                mismatchMessage: "Проверка записанной карты не пройдена. Носитель нельзя считать надежной копией."
            )
            try target.close()

            reporter.update(
                phase: .finalizing,
                processed: inspection.size,
                total: inspection.size,
                message: verification == .skipped
                    ? "Проверка пропущена. Завершаем операцию…"
                    : "Проверка завершена. Завершаем операцию…",
                force: true
            )

            var completionMessage = verification == .skipped
                ? "Карта записана. Финальная проверка была пропущена."
                : "Карта записана и полностью проверена."
            let ejection = ejectIfRequested(disk, requested: ejectAfter)
            shouldMountDisk = !ejection.ejected
            completionMessage += ejection.messageSuffix
            reporter.update(
                phase: .completed,
                processed: inspection.size,
                total: inspection.size,
                message: completionMessage,
                force: true
            )
        } catch {
            try? target.close()
            throw error
        }
    }

    private static func cloneDisk(
        source expectedSource: ExpectedDisk,
        target expectedTarget: ExpectedDisk,
        ejectAfter: Bool,
        reporter: ProgressReporter
    ) throws {
        guard expectedSource.identifier != expectedTarget.identifier else {
            throw AppError.unsafeDisk("Исходный и целевой носители должны быть разными.")
        }

        reporter.update(
            phase: .preparing,
            processed: 0,
            total: expectedSource.size,
            message: "Проверяем исходный и целевой носители…",
            force: true
        )
        let sourceDisk = try waitForExpectedDisk(expectedSource, reporter: reporter)
        let targetDisk = try waitForExpectedDisk(expectedTarget, reporter: reporter)
        guard sourceDisk.size <= targetDisk.size else {
            throw AppError.invalidArguments(
                "Целевой накопитель меньше исходного: нужно минимум \(formattedSize(sourceDisk.size))."
            )
        }

        var shouldMountTarget = true
        defer {
            DiskService.mount(sourceDisk)
            if shouldMountTarget { DiskService.mount(targetDisk) }
        }

        let source = try openExpectedDisk(expectedSource, forWriting: false, reporter: reporter)
        let target: FileHandle
        do {
            target = try openExpectedDisk(expectedTarget, forWriting: true, reporter: reporter)
        } catch {
            try? source.close()
            throw error
        }

        var sourceHasher = SHA256()
        var processed: UInt64 = 0
        do {
            try clearTrailingSignatures(target: target, targetSize: targetDisk.size)
            while processed < sourceDisk.size {
                try reporter.checkCancellation()
                let amount = min(chunkSize, Int(sourceDisk.size - processed))
                let data = try PosixIO.readBlock(from: source, count: amount)
                guard !data.isEmpty else {
                    throw AppError.commandFailed("Исходный носитель закончился раньше ожидаемого размера.")
                }
                try PosixIO.writeAll(data, to: target)
                sourceHasher.update(data: data)
                processed += UInt64(data.count)
                reporter.update(
                    phase: .writing,
                    processed: processed,
                    total: sourceDisk.size,
                    message: "Клонируем носитель…"
                )
            }
            try source.close()
            try target.synchronize()
        } catch {
            try? target.close()
            try? source.close()
            throw error
        }
        let sourceDigest = sourceHasher.finalize().map { String(format: "%02x", $0) }.joined()

        do {
            let verification = try WrittenMediaVerifier.verify(
                handle: target,
                totalSize: sourceDisk.size,
                expectedSHA256: sourceDigest,
                reporter: reporter,
                message: "Сверяем клонированный носитель…",
                prematureReadMessage: "Контрольное чтение клонированного носителя завершилось преждевременно.",
                mismatchMessage: "Проверка клонированного носителя не пройдена. Его нельзя считать надёжной копией."
            )
            try target.close()

            reporter.update(
                phase: .finalizing,
                processed: sourceDisk.size,
                total: sourceDisk.size,
                message: verification == .skipped
                    ? "Проверка пропущена. Завершаем операцию…"
                    : "Проверка завершена. Завершаем операцию…",
                force: true
            )

            var completionMessage = verification == .skipped
                ? "Носитель клонирован. Финальная проверка была пропущена."
                : "Носитель клонирован и полностью проверен."
            let ejection = ejectIfRequested(targetDisk, requested: ejectAfter)
            shouldMountTarget = !ejection.ejected
            completionMessage += ejection.messageSuffix
            reporter.update(
                phase: .completed,
                processed: sourceDisk.size,
                total: sourceDisk.size,
                message: completionMessage,
                force: true
            )
        } catch {
            try? target.close()
            throw error
        }
    }

    private static func ejectIfRequested(
        _ disk: DiskInfo,
        requested: Bool
    ) -> (ejected: Bool, messageSuffix: String) {
        guard requested else { return (false, "") }
        if DiskService.eject(disk) {
            return (true, " Носитель автоматически извлечён.")
        }
        return (false, " Автоматически извлечь носитель не удалось.")
    }

    private static func waitForExpectedDisk(
        _ expected: ExpectedDisk,
        reporter: ProgressReporter,
        deadline: Date? = nil
    ) throws -> DiskInfo {
        let deadline = deadline ?? Date().addingTimeInterval(deviceOpenTimeout)
        var lastError: Error?

        repeat {
            try reporter.checkCancellation()
            do {
                let disk = try DiskService.requireSafeExternalWholeDisk(expected.identifier)
                try validate(disk, matches: expected)
                return disk
            } catch let error as AppError {
                if case .unsafeDisk = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }

            reporter.update(
                phase: .preparing,
                processed: 0,
                total: 0,
                message: "Накопитель отключился. Ожидаем повторное подключение…",
                force: true
            )
            Thread.sleep(forTimeInterval: deviceRetryDelay)
        } while Date() < deadline

        let details = lastError.map { " Последняя ошибка: \($0.localizedDescription)" } ?? ""
        throw AppError.commandFailed(
            "Накопитель \(expected.identifier) исчез из системы. Переподключите карту или кардридер и повторите операцию.\(details)"
        )
    }

    private static func openExpectedDisk(
        _ expected: ExpectedDisk,
        forWriting: Bool,
        reporter: ProgressReporter
    ) throws -> FileHandle {
        let deadline = Date().addingTimeInterval(deviceOpenTimeout)
        var lastFailure = "устройство не найдено"

        repeat {
            let disk = try waitForExpectedDisk(expected, reporter: reporter, deadline: deadline)
            try reporter.checkCancellation()

            do {
                try DiskService.unmount(disk)
            } catch {
                lastFailure = error.localizedDescription
                reporter.update(
                    phase: .preparing,
                    processed: 0,
                    total: 0,
                    message: "Освобождаем накопитель для прямого доступа…",
                    force: true
                )
                Thread.sleep(forTimeInterval: deviceRetryDelay)
                continue
            }

            let flags = (forWriting ? O_RDWR : O_RDONLY) | O_CLOEXEC
            var permissionFailure: String?
            for path in [disk.rawDevicePath, disk.devicePath] {
                let descriptor = Darwin.open(path, flags)
                if descriptor >= 0 {
                    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    PosixIO.configureSequentialDevice(handle)
                    return handle
                }

                let code = errno
                let reason = String(cString: strerror(code))
                lastFailure = "\(path): \(reason) (errno \(code))"
                if code == EACCES || code == EPERM {
                    permissionFailure = lastFailure
                }
            }

            if let permissionFailure {
                throw AppError.commandFailed(
                    "macOS заблокировала прямой доступ к накопителю. Включите «Полный доступ к диску» для приложения «Simple Imager» в разделе «Конфиденциальность и безопасность», затем полностью перезапустите приложение. \(permissionFailure)"
                )
            }

            reporter.update(
                phase: .preparing,
                processed: 0,
                total: 0,
                message: "Накопитель временно недоступен. Пробуем снова…",
                force: true
            )
            Thread.sleep(forTimeInterval: deviceRetryDelay)
        } while Date() < deadline

        let operation = forWriting ? "записи" : "чтения"
        throw AppError.commandFailed(
            "Не удалось открыть накопитель для \(operation) за \(Int(deviceOpenTimeout)) секунд. \(lastFailure). Проверьте карту, кардридер и кабель."
        )
    }

    private static func validate(_ disk: DiskInfo, matches expected: ExpectedDisk) throws {
        guard disk.identifier == expected.identifier,
              disk.size == expected.size,
              disk.mediaName == expected.mediaName else {
            throw AppError.unsafeDisk(
                "После переподключения под именем \(expected.identifier) обнаружен другой накопитель. Обновите список и выберите карту заново."
            )
        }
    }

    private static func inspectImage(
        inputURL: URL,
        format: ImageFileFormat,
        reporter: ProgressReporter
    ) throws -> ImageInspection {
        var hasher = SHA256()
        var count: UInt64 = 0
        let uncompressedSize = format.compression == .none
            ? ((try? FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? NSNumber)?.uint64Value ?? 0)
            : 0

        try streamDecoded(inputURL: inputURL, format: format, reporter: reporter) { data in
            count += UInt64(data.count)
            hasher.update(data: data)
            reporter.update(
                phase: .verifyingArchive,
                processed: count,
                total: uncompressedSize,
                message: "Проверяем образ и определяем его размер…"
            )
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ImageInspection(size: count, sha256: digest)
    }

    private static func writeDecompressedImage(
        inputURL: URL,
        target: FileHandle,
        expectedSize: UInt64,
        format: ImageFileFormat,
        reporter: ProgressReporter
    ) throws -> String {
        try target.seek(toOffset: 0)
        var written: UInt64 = 0
        var hasher = SHA256()
        try streamDecoded(inputURL: inputURL, format: format, reporter: reporter) { data in
            written += UInt64(data.count)
            guard written <= expectedSize else {
                throw AppError.archiveInvalid("Образ неожиданно превышает заявленный размер.")
            }
            try PosixIO.writeAll(data, to: target)
            hasher.update(data: data)
            reporter.update(phase: .writing, processed: written, total: expectedSize, message: "Записываем образ на карту…")
        }
        guard written == expectedSize else {
            throw AppError.archiveInvalid("На карту записан неполный образ.")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func streamDecoded(
        inputURL: URL,
        format: ImageFileFormat,
        reporter: ProgressReporter,
        consume: (Data) throws -> Void
    ) throws {
        if format.compression == .none {
            let source = try FileHandle(forReadingFrom: inputURL)
            defer { try? source.close() }
            while true {
                try reporter.checkCancellation()
                let data = try PosixIO.readBlock(from: source, count: chunkSize)
                guard !data.isEmpty else { break }
                try consume(data)
            }
            return
        }

        if format.compression.isArchiveContainer {
            try validateSingleFileArchive(inputURL)
        }
        guard let executable = format.compression.executable(for: .decode) else {
            throw missingCodecError(format.compression)
        }

        let process = Process()
        let output = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = decoderArguments(
            compression: format.compression,
            executable: executable,
            inputURL: inputURL
        )
        process.standardOutput = output
        process.standardError = errorPipe
        try process.run()

        do {
            while true {
                try reporter.checkCancellation()
                let data = try PosixIO.readBlock(from: output.fileHandleForReading, count: chunkSize)
                guard !data.isEmpty else { break }
                try consume(data)
            }
            process.waitUntilExit()
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }

        guard process.terminationStatus == 0 else {
            let details = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw AppError.archiveInvalid("\(format.compression.title) не смог распаковать образ. \(details)")
        }
    }

    private static func validateSingleFileArchive(_ inputURL: URL) throws {
        let process = Process()
        let output = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ["-tf", inputURL.path]
        process.standardOutput = output
        process.standardError = errorPipe
        try process.run()
        let listingData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let details = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw AppError.archiveInvalid("Не удалось прочитать структуру архива. \(details)")
        }
        let listing = String(data: listingData, encoding: .utf8) ?? ""
        let files = listing.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty && !$0.hasSuffix("/") }
        guard files.count == 1 else {
            throw AppError.archiveInvalid("ZIP и 7Z должны содержать ровно один файл образа.")
        }
    }

    private static func decoderArguments(
        compression: ImageCompression,
        executable: String,
        inputURL: URL
    ) -> [String] {
        switch compression {
        case .none:
            []
        case .zstd, .lz4:
            ["-d", "-q", "-c", inputURL.path]
        case .gzip, .xz, .bzip2:
            ["-d", "-c", inputURL.path]
        case .zip:
            ["-p", inputURL.path]
        case .sevenZip:
            executable == "/usr/bin/bsdtar"
                ? ["-xOf", inputURL.path]
                : ["x", "-so", "-bd", "-y", inputURL.path]
        }
    }

    private static func encoderArguments(
        compression: ImageCompression,
        outputURL: URL,
        archiveEntryName: String
    ) -> [String] {
        switch compression {
        case .none:
            []
        case .zstd:
            ["-3", "-T0", "-q", "-c"]
        case .gzip:
            ["-6", "-c"]
        case .xz:
            ["-3", "-T0", "-c"]
        case .bzip2:
            ["-5", "-c"]
        case .lz4:
            ["-q", "-c"]
        case .zip:
            ["-q", outputURL.path, "-"]
        case .sevenZip:
            [
                "a", "-t7z", "-mx=3", "-bd", "-bso0", "-bsp0", "-y",
                outputURL.path, "-si\(archiveEntryName)"
            ]
        }
    }

    private static func codecWritesToStandardOutput(_ compression: ImageCompression) -> Bool {
        switch compression {
        case .zstd, .gzip, .xz, .bzip2, .lz4:
            true
        case .none, .zip, .sevenZip:
            false
        }
    }

    private static func missingCodecError(_ compression: ImageCompression) -> AppError {
        if let hint = compression.installHint {
            return AppError.invalidArguments("Для формата \(compression.title) требуется выполнить: \(hint)")
        }
        return AppError.invalidArguments("На этом Mac отсутствует инструмент для формата \(compression.title).")
    }

    private static func clearTrailingSignatures(target: FileHandle, targetSize: UInt64) throws {
        let amount = min(UInt64(chunkSize), targetSize)
        guard amount > 0 else { return }
        try target.seek(toOffset: targetSize - amount)
        try PosixIO.writeAll(Data(repeating: 0, count: Int(amount)), to: target)
        try target.seek(toOffset: 0)
    }

    private static func replaceItem(at destination: URL, with temporary: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static func allocatedFileSize(at url: URL) -> UInt64? {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return nil }
        return UInt64(information.st_blocks) * 512
    }

    private static func formattedSize(_ size: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .decimal)
    }

    private static func setOwnership(paths: [String], owner: String?) throws {
        guard let owner,
              owner.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return }
        let output = try CommandRunner.run("/usr/sbin/chown", [owner] + paths)
        guard output.status == 0 else {
            throw AppError.commandFailed("Образ создан, но не удалось передать пользователю права на файл.")
        }
    }

    private static func ensureDestinationIsNot(on source: DiskInfo, outputURL: URL) throws {
        let parentPath = outputURL.deletingLastPathComponent().path
        guard let data = try? CommandRunner.requireSuccess("/usr/sbin/diskutil", ["info", "-plist", parentPath]),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let values = plist as? [String: Any] else { return }
        let parentDisk = values["ParentWholeDisk"] as? String ?? values["DeviceIdentifier"] as? String
        if parentDisk == source.identifier {
            throw AppError.unsafeDisk("Нельзя сохранять образ на ту же карту, которую приложение будет размонтировать.")
        }
    }

    private static func parse(arguments: [String]) throws -> [String: String] {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), index + 1 < arguments.count else {
                throw AppError.invalidArguments("Некорректные аргументы helper-процесса.")
            }
            values[String(key.dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        return values
    }

    private static func writeTerminalProgress(arguments: [String], phase: JobPhase, message: String) {
        guard let values = try? parse(arguments: arguments),
              let progressPath = values["progress"] else { return }
        let progress = JobProgress(phase: phase, processedBytes: 0, totalBytes: 0, message: message)
        if let data = try? JSONEncoder().encode(progress) {
            try? data.write(to: URL(fileURLWithPath: progressPath), options: .atomic)
        }
    }

    private final class ImageEncoder {
        private let compression: ImageCompression
        private let sparse: Bool
        private var directHandle: FileHandle?
        private var process: Process?
        private var processInput: FileHandle?
        private var errorPipe: Pipe?
        private var outputHandle: FileHandle?
        private var nullHandle: FileHandle?
        private var sparseRanges: [SparseRange] = []
        private var finished = false

        init(
            compression: ImageCompression,
            outputURL: URL,
            archiveEntryName: String,
            sparse: Bool
        ) throws {
            self.compression = compression
            self.sparse = sparse

            if compression == .none {
                guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
                    throw AppError.commandFailed("Не удалось создать файл образа.")
                }
                directHandle = try FileHandle(forWritingTo: outputURL)
                return
            }

            guard let executable = compression.executable(for: .encode) else {
                throw ImagingHelper.missingCodecError(compression)
            }

            let process = Process()
            let inputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ImagingHelper.encoderArguments(
                compression: compression,
                outputURL: outputURL,
                archiveEntryName: archiveEntryName
            )
            process.standardInput = inputPipe
            process.standardError = errorPipe

            if ImagingHelper.codecWritesToStandardOutput(compression) {
                guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
                    throw AppError.commandFailed("Не удалось создать файл образа.")
                }
                let outputHandle = try FileHandle(forWritingTo: outputURL)
                process.standardOutput = outputHandle
                self.outputHandle = outputHandle
            } else {
                let nullHandle = FileHandle(forWritingAtPath: "/dev/null")
                process.standardOutput = nullHandle
                self.nullHandle = nullHandle
            }

            self.process = process
            self.processInput = inputPipe.fileHandleForWriting
            self.errorPipe = errorPipe
            try process.run()
        }

        func write(_ data: Data) throws {
            guard !finished else {
                throw AppError.commandFailed("Поток образа уже закрыт.")
            }
            if let directHandle {
                if sparse {
                    let result = try PosixIO.writeSparse(data, to: directHandle)
                    for range in result.ranges { appendSparseRange(range) }
                } else {
                    try PosixIO.writeAll(data, to: directHandle)
                }
            } else if let processInput {
                try PosixIO.writeAll(data, to: processInput)
            } else {
                throw AppError.commandFailed("Не удалось открыть поток сжатия.")
            }
        }

        func finish() throws {
            guard !finished else { return }

            if let directHandle {
                if sparse { try PosixIO.finalizeSparseFile(directHandle, ranges: sparseRanges) }
                try directHandle.synchronize()
                try directHandle.close()
                self.directHandle = nil
                finished = true
                return
            }

            try processInput?.close()
            processInput = nil
            process?.waitUntilExit()
            try outputHandle?.synchronize()
            try outputHandle?.close()
            outputHandle = nil
            try nullHandle?.close()
            nullHandle = nil
            finished = true

            guard process?.terminationStatus == 0 else {
                let details = errorPipe.map {
                    String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                } ?? ""
                throw AppError.commandFailed("\(compression.title) не смог создать образ. \(details)")
            }
        }

        func cancel() {
            guard !finished else { return }
            try? directHandle?.close()
            try? processInput?.close()
            if process?.isRunning == true { process?.terminate() }
            process?.waitUntilExit()
            try? outputHandle?.close()
            try? nullHandle?.close()
            directHandle = nil
            processInput = nil
            outputHandle = nil
            nullHandle = nil
            finished = true
        }

        private func appendSparseRange(_ range: SparseRange) {
            guard let previous = sparseRanges.last,
                  previous.offset + previous.length >= range.offset else {
                sparseRanges.append(range)
                return
            }
            let end = max(previous.offset + previous.length, range.offset + range.length)
            sparseRanges[sparseRanges.count - 1] = SparseRange(
                offset: previous.offset,
                length: end - previous.offset
            )
        }

        deinit {
            cancel()
        }
    }

    private struct ImageInspection {
        let size: UInt64
        let sha256: String
    }

    private struct ExpectedDisk {
        let identifier: String
        let mediaName: String
        let size: UInt64
    }
}
