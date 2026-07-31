import CryptoKit
import Darwin
import Foundation

enum ImagingHelper {
    private static let chunkSize = 4 * 1024 * 1024
    private static let allowedZstdPaths = [
        "/opt/homebrew/bin/zstd",
        "/usr/local/bin/zstd",
        "/usr/bin/zstd"
    ]

    static func run(arguments: [String]) -> Int32 {
        do {
            guard geteuid() == 0 else {
                throw AppError.unsafeDisk("Для доступа к карте требуются права администратора.")
            }
            let values = try parse(arguments: arguments)
            guard let action = values["action"],
                  let device = values["device"],
                  let progressPath = values["progress"],
                  let cancelPath = values["cancel"],
                  let zstd = values["zstd"] else {
                throw AppError.invalidArguments("Не хватает аргументов helper-процесса.")
            }
            guard allowedZstdPaths.contains(zstd), FileManager.default.isExecutableFile(atPath: zstd) else {
                throw AppError.invalidArguments("Не найден доверенный исполняемый файл zstd.")
            }

            let reporter = ProgressReporter(
                progressURL: URL(fileURLWithPath: progressPath),
                cancelURL: URL(fileURLWithPath: cancelPath)
            )

            switch action {
            case "create":
                guard let output = values["output"],
                      let modeValue = values["mode"],
                      let mode = CaptureMode(rawValue: modeValue) else {
                    throw AppError.invalidArguments("Не указаны параметры создания образа.")
                }
                try createImage(
                    device: device,
                    outputURL: URL(fileURLWithPath: output),
                    mode: mode,
                    zstdPath: zstd,
                    owner: values["owner"],
                    reporter: reporter
                )
            case "restore":
                guard let input = values["input"] else {
                    throw AppError.invalidArguments("Не указан файл образа.")
                }
                try restoreImage(
                    device: device,
                    inputURL: URL(fileURLWithPath: input),
                    verifyAfterWrite: values["verify"] != "false",
                    zstdPath: zstd,
                    reporter: reporter
                )
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
        device: String,
        outputURL: URL,
        mode: CaptureMode,
        zstdPath: String,
        owner: String?,
        reporter: ProgressReporter
    ) throws {
        reporter.update(phase: .preparing, processed: 0, total: 0, message: "Проверяем карту…", force: true)
        let disk = try DiskService.requireSafeExternalWholeDisk(device)
        try reporter.checkCancellation()
        try ensureDestinationIsNot(on: disk, outputURL: outputURL)

        let parent = outputURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppError.invalidArguments("Папка для образа не существует.")
        }

        try DiskService.unmount(disk)
        defer { DiskService.mount(disk) }

        guard let source = FileHandle(forReadingAtPath: disk.rawDevicePath) else {
            throw AppError.commandFailed("Не удалось открыть \(disk.rawDevicePath) для чтения.")
        }
        defer { try? source.close() }

        var compactPlan = CompactPlan(regions: [], rawPartitions: [])
        if mode == .compact {
            reporter.update(phase: .analyzing, processed: 0, total: disk.size, message: "Ищем свободные кластеры FAT32/exFAT…", force: true)
            compactPlan = CompactImageAnalyzer.buildPlan(handle: source, diskSize: disk.size)
        }
        try source.seek(toOffset: 0)

        let temporaryURL = parent.appendingPathComponent(".\(outputURL.lastPathComponent).partial-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let compressor = Process()
        let compressorInput = Pipe()
        let compressorError = Pipe()
        compressor.executableURL = URL(fileURLWithPath: zstdPath)
        compressor.arguments = ["-3", "-T0", "-q", "-f", "-o", temporaryURL.path]
        compressor.standardInput = compressorInput
        compressor.standardError = compressorError
        try compressor.run()

        var hasher = SHA256()
        var processed: UInt64 = 0
        do {
            while processed < disk.size {
                try reporter.checkCancellation()
                let amount = min(chunkSize, Int(disk.size - processed))
                guard var data = try source.read(upToCount: amount), !data.isEmpty else {
                    throw AppError.commandFailed("Карта закончилась раньше ожидаемого размера.")
                }
                if mode == .compact {
                    compactPlan.sanitize(&data, at: processed)
                }
                hasher.update(data: data)
                try compressorInput.fileHandleForWriting.write(contentsOf: data)
                processed += UInt64(data.count)
                reporter.update(
                    phase: .reading,
                    processed: processed,
                    total: disk.size,
                    message: "Читаем карту и сжимаем образ…"
                )
            }
            try compressorInput.fileHandleForWriting.close()
            compressor.waitUntilExit()
        } catch {
            try? compressorInput.fileHandleForWriting.close()
            if compressor.isRunning { compressor.terminate() }
            compressor.waitUntilExit()
            throw error
        }

        guard compressor.terminationStatus == 0 else {
            let details = String(data: compressorError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw AppError.commandFailed("zstd не смог создать архив. \(details)")
        }

        reporter.update(phase: .finalizing, processed: disk.size, total: disk.size, message: "Сохраняем манифест…", force: true)
        try replaceItem(at: outputURL, with: temporaryURL)

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let manifest = ImageManifest(
            formatVersion: ImageManifest.currentFormatVersion,
            createdAt: Date(),
            sourceDevice: disk.identifier,
            sourceMediaName: disk.mediaName,
            sourceSize: disk.size,
            imageFileName: outputURL.lastPathComponent,
            compression: "zstd",
            compressionLevel: 3,
            sha256: digest,
            captureMode: mode,
            compactedFileSystems: compactPlan.compactedFileSystems,
            rawPartitions: compactPlan.rawPartitions
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifestURL = outputURL.appendingPathExtension("json")
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        try setOwnership(paths: [outputURL.path, manifestURL.path], owner: owner)

        let detail = compactPlan.compactedFileSystems.isEmpty && mode == .compact
            ? "Образ создан. Поддерживаемые FAT32/exFAT-разделы не найдены, данные сохранены полностью."
            : "Образ и контрольная сумма сохранены."
        reporter.update(phase: .completed, processed: disk.size, total: disk.size, message: detail, force: true)
    }

    private static func restoreImage(
        device: String,
        inputURL: URL,
        verifyAfterWrite: Bool,
        zstdPath: String,
        reporter: ProgressReporter
    ) throws {
        reporter.update(phase: .preparing, processed: 0, total: 0, message: "Проверяем образ и целевую карту…", force: true)
        let disk = try DiskService.requireSafeExternalWholeDisk(device)
        let manifest = try loadManifest(for: inputURL)
        guard manifest.sourceSize <= disk.size else {
            throw AppError.archiveInvalid(
                "Целевая карта меньше исходной: нужно минимум \(ByteCountFormatter.string(fromByteCount: Int64(manifest.sourceSize), countStyle: .decimal))."
            )
        }

        try reporter.checkCancellation()
        let archiveDigest = try digestDecompressedImage(
            inputURL: inputURL,
            expectedSize: manifest.sourceSize,
            zstdPath: zstdPath,
            phase: .verifyingArchive,
            reporter: reporter
        )
        guard archiveDigest == manifest.sha256.lowercased() else {
            throw AppError.archiveInvalid("SHA-256 образа не совпадает с манифестом. Запись не начата.")
        }

        try reporter.checkCancellation()
        try DiskService.unmount(disk)
        defer { DiskService.mount(disk) }

        guard let target = FileHandle(forWritingAtPath: disk.rawDevicePath) else {
            throw AppError.commandFailed("Не удалось открыть \(disk.rawDevicePath) для записи.")
        }
        do {
            try clearTrailingSignatures(target: target, targetSize: disk.size)
            try writeDecompressedImage(
                inputURL: inputURL,
                target: target,
                expectedSize: manifest.sourceSize,
                zstdPath: zstdPath,
                reporter: reporter
            )
            try target.synchronize()
            try target.close()
        } catch {
            try? target.close()
            throw error
        }

        if verifyAfterWrite {
            reporter.update(phase: .verifyingCard, processed: 0, total: manifest.sourceSize, message: "Сверяем записанную карту…", force: true)
            guard let verificationSource = FileHandle(forReadingAtPath: disk.rawDevicePath) else {
                throw AppError.commandFailed("Не удалось открыть карту для контрольного чтения.")
            }
            defer { try? verificationSource.close() }

            var hasher = SHA256()
            var processed: UInt64 = 0
            while processed < manifest.sourceSize {
                try reporter.checkCancellation()
                let amount = min(chunkSize, Int(manifest.sourceSize - processed))
                guard let data = try verificationSource.read(upToCount: amount), !data.isEmpty else {
                    throw AppError.commandFailed("Контрольное чтение завершилось преждевременно.")
                }
                hasher.update(data: data)
                processed += UInt64(data.count)
                reporter.update(phase: .verifyingCard, processed: processed, total: manifest.sourceSize, message: "Сверяем записанную карту…")
            }
            let writtenDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard writtenDigest == manifest.sha256.lowercased() else {
                throw AppError.archiveInvalid("Проверка записанной карты не пройдена. Носитель нельзя считать надежной копией.")
            }
        }

        reporter.update(phase: .completed, processed: manifest.sourceSize, total: manifest.sourceSize, message: "Карта записана и готова к использованию.", force: true)
    }

    private static func digestDecompressedImage(
        inputURL: URL,
        expectedSize: UInt64,
        zstdPath: String,
        phase: JobPhase,
        reporter: ProgressReporter
    ) throws -> String {
        var hasher = SHA256()
        var count: UInt64 = 0
        try streamDecompressed(inputURL: inputURL, zstdPath: zstdPath, reporter: reporter) { data in
            count += UInt64(data.count)
            guard count <= expectedSize else {
                throw AppError.archiveInvalid("Распакованный образ больше размера из манифеста.")
            }
            hasher.update(data: data)
            reporter.update(phase: phase, processed: count, total: expectedSize, message: "Проверяем целостность архива…")
        }
        guard count == expectedSize else {
            throw AppError.archiveInvalid("Размер распакованного образа не совпадает с манифестом.")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func writeDecompressedImage(
        inputURL: URL,
        target: FileHandle,
        expectedSize: UInt64,
        zstdPath: String,
        reporter: ProgressReporter
    ) throws {
        try target.seek(toOffset: 0)
        var written: UInt64 = 0
        try streamDecompressed(inputURL: inputURL, zstdPath: zstdPath, reporter: reporter) { data in
            written += UInt64(data.count)
            guard written <= expectedSize else {
                throw AppError.archiveInvalid("Образ неожиданно превышает заявленный размер.")
            }
            try target.write(contentsOf: data)
            reporter.update(phase: .writing, processed: written, total: expectedSize, message: "Записываем образ на карту…")
        }
        guard written == expectedSize else {
            throw AppError.archiveInvalid("На карту записан неполный образ.")
        }
    }

    private static func streamDecompressed(
        inputURL: URL,
        zstdPath: String,
        reporter: ProgressReporter,
        consume: (Data) throws -> Void
    ) throws {
        let process = Process()
        let output = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: zstdPath)
        process.arguments = ["-d", "-q", "-c", inputURL.path]
        process.standardOutput = output
        process.standardError = errorPipe
        try process.run()

        do {
            while true {
                try reporter.checkCancellation()
                guard let data = try output.fileHandleForReading.read(upToCount: chunkSize), !data.isEmpty else { break }
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
            throw AppError.archiveInvalid("zstd не смог распаковать образ. \(details)")
        }
    }

    private static func clearTrailingSignatures(target: FileHandle, targetSize: UInt64) throws {
        let amount = min(UInt64(chunkSize), targetSize)
        guard amount > 0 else { return }
        try target.seek(toOffset: targetSize - amount)
        try target.write(contentsOf: Data(repeating: 0, count: Int(amount)))
        try target.seek(toOffset: 0)
    }

    private static func loadManifest(for inputURL: URL) throws -> ImageManifest {
        let manifestURL = inputURL.appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: inputURL.path),
              FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw AppError.archiveInvalid("Рядом с образом должен находиться файл \(manifestURL.lastPathComponent).")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ImageManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.formatVersion == ImageManifest.currentFormatVersion,
              manifest.compression == "zstd",
              manifest.sourceSize > 0,
              manifest.sha256.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil else {
            throw AppError.archiveInvalid("Манифест образа имеет неподдерживаемый формат.")
        }
        return manifest
    }

    private static func replaceItem(at destination: URL, with temporary: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
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
}
