import Darwin
import Foundation

struct ExtShrinkPlan: Equatable {
    let partitionIndex: Int
    let firstLBA: UInt64
    let sectorCount: UInt64

    var partitionOffset: UInt64 { firstLBA * 512 }
    var partitionLength: UInt64 { sectorCount * 512 }
}

struct ExtShrinkResult: Equatable {
    let logicalSize: UInt64
    let autoExpandStatus: ExtAutoExpandStatus
}

enum ExtAutoExpandStatus: Equatable {
    case notRequested
    case installed
    case systemdUnavailable
}

enum NativeExtImageShrinker {
    private static let hdiutil = "/usr/bin/hdiutil"
    private static let extendedPartitionTypes: Set<UInt8> = [0x05, 0x0F, 0x85]
    private static let safetyMarginBytes: UInt64 = 64 * 1024 * 1024
    private static let autoExpandScriptPath = "/usr/local/sbin/sd-archiver-grow-rootfs"
    private static let autoExpandServicePath = "/etc/systemd/system/sd-archiver-grow-rootfs.service"
    private static let autoExpandLinkPath = "/etc/systemd/system/multi-user.target.wants/sd-archiver-grow-rootfs.service"

    static var dependencyMessage: String? {
        missingToolNames.isEmpty
            ? nil
            : "Для уменьшения ext2/3/4 требуется: brew install e2fsprogs"
    }

    static var isAvailable: Bool { dependencyMessage == nil }

    static func analyze(handle: FileHandle, diskSize: UInt64) throws -> ExtShrinkPlan {
        guard diskSize >= 512 else {
            throw unsupported("Накопитель слишком мал для таблицы разделов MBR.")
        }

        let mbr = try PosixIO.readExact(from: handle, offset: 0, count: 512)
        guard mbr.byte(at: 510) == 0x55, mbr.byte(at: 511) == 0xAA else {
            throw unsupported("Таблица разделов MBR не найдена.")
        }

        var entries: [(index: Int, type: UInt8, firstLBA: UInt64, sectors: UInt64)] = []
        for index in 0..<4 {
            let offset = 446 + index * 16
            let type = mbr.byte(at: offset + 4)
            let firstLBA = UInt64(mbr.littleUInt32(at: offset + 8) ?? 0)
            let sectors = UInt64(mbr.littleUInt32(at: offset + 12) ?? 0)
            guard type != 0, sectors > 0 else { continue }
            entries.append((index, type, firstLBA, sectors))
        }

        guard !entries.isEmpty else {
            throw unsupported("В MBR не найдено ни одного раздела.")
        }
        guard !entries.contains(where: { $0.type == 0xEE }) else {
            throw unsupported("GPT пока не поддерживается.")
        }
        guard !entries.contains(where: { extendedPartitionTypes.contains($0.type) }) else {
            throw unsupported("Расширенные и логические разделы пока не поддерживаются.")
        }

        let diskSectors = diskSize / 512
        for entry in entries {
            guard entry.firstLBA < diskSectors,
                  entry.sectors <= diskSectors - entry.firstLBA else {
                throw unsupported("Один из разделов выходит за границы накопителя.")
            }
        }

        guard let last = entries.max(by: {
            $0.firstLBA + $0.sectors < $1.firstLBA + $1.sectors
        }), last.type == 0x83 else {
            throw unsupported("Последний основной раздел должен иметь Linux-тип 0x83.")
        }

        let plan = ExtShrinkPlan(
            partitionIndex: last.index,
            firstLBA: last.firstLBA,
            sectorCount: last.sectors
        )
        let superblockSectorOffset = plan.partitionOffset + 1024
        guard superblockSectorOffset + 512 <= diskSize else {
            throw unsupported("Раздел слишком мал для ext2/3/4.")
        }
        // Raw disks reject non-sector-aligned pread calls with EINVAL.
        let superblockSector = try PosixIO.readExact(
            from: handle,
            offset: superblockSectorOffset,
            count: 512
        )
        guard superblockSector.littleUInt16(at: 56) == 0xEF53 else {
            throw unsupported("В последнем разделе не найдена файловая система ext2/3/4.")
        }
        return plan
    }

    static func shrink(
        imageURL: URL,
        plan: ExtShrinkPlan,
        autoExpand: Bool,
        reporter: ProgressReporter
    ) throws -> ExtShrinkResult {
        if let dependencyMessage { throw AppError.invalidArguments(dependencyMessage) }

        reporter.update(
            phase: .shrinking,
            processed: 0,
            total: plan.partitionLength,
            message: "Проверяем файловую систему ext…",
            force: true
        )

        let attachment = try attach(imageURL: imageURL, reporter: reporter)
        var isAttached = true
        defer {
            if isAttached { _ = try? detach(attachment.wholeDevice) }
        }

        let partitionDevice = partitionDevice(
            wholeDevice: attachment.wholeDevice,
            partitionIndex: plan.partitionIndex
        )
        guard FileManager.default.fileExists(atPath: partitionDevice) else {
            throw AppError.commandFailed("macOS не создала устройство для уменьшаемого ext-раздела.")
        }

        try runFileSystemCheck(partitionDevice, reporter: reporter)
        let autoExpandStatus: ExtAutoExpandStatus
        if autoExpand {
            reporter.update(
                phase: .shrinking,
                processed: 0,
                total: plan.partitionLength,
                message: "Добавляем авторасширение ext при первой загрузке…",
                force: true
            )
            autoExpandStatus = try installAutoExpansion(
                partitionDevice,
                reporter: reporter
            )
            if autoExpandStatus == .installed {
                try runFileSystemCheck(partitionDevice, reporter: reporter)
            }
        } else {
            autoExpandStatus = .notRequested
        }

        let minimumBlocks = try minimumBlockCount(partitionDevice, reporter: reporter)
        let initialGeometry = try fileSystemGeometry(partitionDevice, reporter: reporter)
        guard minimumBlocks > 0, minimumBlocks <= initialGeometry.blockCount else {
            throw AppError.commandFailed("resize2fs вернул некорректный минимальный размер файловой системы.")
        }

        let marginBlocks = max(
            UInt64(4096),
            (safetyMarginBytes + initialGeometry.blockSize - 1) / initialGeometry.blockSize
        )
        let targetBlocks = min(
            initialGeometry.blockCount,
            minimumBlocks.addingClamped(marginBlocks)
        )

        if targetBlocks < initialGeometry.blockCount {
            reporter.update(
                phase: .shrinking,
                processed: 0,
                total: initialGeometry.blockCount,
                message: "Уменьшаем файловую систему ext…",
                force: true
            )
            let resize = try runTool(
                executable: try requiredTool("resize2fs"),
                arguments: ["-p", partitionDevice, String(targetBlocks)],
                reporter: reporter
            )
            guard resize.status == 0 else {
                throw toolFailure("resize2fs не смог уменьшить файловую систему", resize)
            }
        }

        try runFileSystemCheck(partitionDevice, reporter: reporter)
        let finalGeometry = try fileSystemGeometry(partitionDevice, reporter: reporter)
        guard finalGeometry.blockSize > 0,
              finalGeometry.blockCount <= UInt64.max / finalGeometry.blockSize else {
            throw AppError.commandFailed("Не удалось вычислить итоговый размер файловой системы.")
        }
        let fileSystemBytes = finalGeometry.blockCount * finalGeometry.blockSize
        let newSectorCount = (fileSystemBytes + 511) / 512
        guard newSectorCount > 0,
              newSectorCount <= plan.sectorCount,
              newSectorCount <= UInt64(UInt32.max) else {
            throw AppError.commandFailed("Итоговый раздел не помещается в таблицу MBR.")
        }

        reporter.update(
            phase: .shrinking,
            processed: fileSystemBytes,
            total: plan.partitionLength,
            message: "Обнуляем свободные блоки ext…",
            force: true
        )
        let freeBlockRanges = try collectFreeBlockRanges(
            partitionDevice,
            geometry: finalGeometry,
            partitionOffset: plan.partitionOffset,
            reporter: reporter
        )
        try runFileSystemCheck(partitionDevice, reporter: reporter)

        try detach(attachment.wholeDevice)
        isAttached = false

        let imageHandle = try FileHandle(forUpdating: imageURL)
        do {
            try PosixIO.replaceWithZeroOrSparseRanges(
                imageHandle,
                ranges: freeBlockRanges
            )
            try imageHandle.close()
        } catch {
            try? imageHandle.close()
            throw error
        }

        reporter.update(
            phase: .shrinking,
            processed: fileSystemBytes,
            total: plan.partitionLength,
            message: "Обновляем таблицу разделов и размер образа…",
            force: true
        )
        let logicalSize = try updateMBRAndTruncate(
            imageURL: imageURL,
            plan: plan,
            newSectorCount: newSectorCount
        )
        return ExtShrinkResult(
            logicalSize: logicalSize,
            autoExpandStatus: autoExpandStatus
        )
    }

    private static var missingToolNames: [String] {
        ["debugfs", "e2fsck", "resize2fs", "tune2fs"].filter { executable(named: $0) == nil }
    }

    private static func executable(named name: String) -> String? {
        let candidates = [
            "/opt/homebrew/opt/e2fsprogs/sbin/\(name)",
            "/usr/local/opt/e2fsprogs/sbin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func requiredTool(_ name: String) throws -> String {
        guard let executable = executable(named: name) else {
            throw AppError.invalidArguments("Не найден \(name). Выполните: brew install e2fsprogs")
        }
        return executable
    }

    private static func attach(
        imageURL: URL,
        reporter: ProgressReporter
    ) throws -> (wholeDevice: String, output: String) {
        let result = try runTool(
            executable: hdiutil,
            arguments: [
                "attach", "-nomount", "-noverify",
                "-imagekey", "diskimage-class=CRawDiskImage",
                imageURL.path
            ],
            reporter: reporter
        )
        guard result.status == 0 else {
            throw toolFailure("Не удалось подключить временный образ", result)
        }

        let output = result.output + "\n" + result.error
        let wholeDevice = output
            .split(whereSeparator: \Character.isNewline)
            .compactMap { line -> String? in
                guard let first = line.split(whereSeparator: \Character.isWhitespace).first else { return nil }
                let value = String(first)
                return value.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil
                    ? value
                    : nil
            }
            .first
        guard let wholeDevice else {
            throw AppError.commandFailed("hdiutil подключил образ, но не сообщил имя устройства. \(output)")
        }
        return (wholeDevice, output)
    }

    private static func detach(_ wholeDevice: String) throws {
        let result = try runTool(
            executable: hdiutil,
            arguments: ["detach", "-force", wholeDevice],
            reporter: nil
        )
        guard result.status == 0 else {
            throw toolFailure("Не удалось отключить временный образ", result)
        }
    }

    private static func partitionDevice(wholeDevice: String, partitionIndex: Int) -> String {
        wholeDevice + "s\(partitionIndex + 1)"
    }

    private static func installAutoExpansion(
        _ device: String,
        reporter: ProgressReporter
    ) throws -> ExtAutoExpandStatus {
        guard try debugfsPathExists("/etc/systemd/system", on: device, reporter: reporter) else {
            return .systemdUnavailable
        }

        try ensureDebugfsDirectory(
            "/etc/systemd/system/multi-user.target.wants",
            parent: "/etc/systemd/system",
            on: device,
            reporter: reporter
        )
        try ensureDebugfsDirectory(
            "/usr/local",
            parent: "/usr",
            on: device,
            reporter: reporter
        )
        try ensureDebugfsDirectory(
            "/usr/local/sbin",
            parent: "/usr/local",
            on: device,
            reporter: reporter
        )

        let identifier = UUID().uuidString
        let scriptURL = URL(fileURLWithPath: "/tmp/sd-archiver-grow-\(identifier).sh")
        let serviceURL = URL(fileURLWithPath: "/tmp/sd-archiver-grow-\(identifier).service")
        try Data(autoExpandScript.utf8).write(to: scriptURL, options: .atomic)
        try Data(autoExpandService.utf8).write(to: serviceURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: serviceURL)
        }

        for path in [autoExpandLinkPath, autoExpandServicePath, autoExpandScriptPath] {
            try removeDebugfsPath(path, on: device, reporter: reporter)
        }

        do {
            try writeDebugfsFile(
                from: scriptURL,
                to: autoExpandScriptPath,
                mode: "0100755",
                on: device,
                reporter: reporter
            )
            try writeDebugfsFile(
                from: serviceURL,
                to: autoExpandServicePath,
                mode: "0100644",
                on: device,
                reporter: reporter
            )
            try requireDebugfsCommand(
                "symlink \(autoExpandLinkPath) ../sd-archiver-grow-rootfs.service",
                on: device,
                reporter: reporter
            )

            guard try debugfsPathExists(autoExpandLinkPath, on: device, reporter: reporter),
                  try debugfsContents(of: autoExpandScriptPath, on: device, reporter: reporter)
                    .contains("SD_ARCHIVER_AUTOEXPAND") else {
                throw AppError.commandFailed("Не удалось проверить файлы авторасширения в ext-образе.")
            }
        } catch {
            for path in [autoExpandLinkPath, autoExpandServicePath, autoExpandScriptPath] {
                try? removeDebugfsPath(path, on: device, reporter: reporter)
            }
            throw error
        }
        return .installed
    }

    private static func ensureDebugfsDirectory(
        _ path: String,
        parent: String,
        on device: String,
        reporter: ProgressReporter
    ) throws {
        if try debugfsPathExists(path, on: device, reporter: reporter) { return }
        guard try debugfsPathExists(parent, on: device, reporter: reporter) else {
            throw AppError.commandFailed("В Linux-образе отсутствует каталог \(parent).")
        }
        try requireDebugfsCommand("mkdir \(path)", on: device, reporter: reporter)
        guard try debugfsPathExists(path, on: device, reporter: reporter) else {
            throw AppError.commandFailed("Не удалось создать каталог \(path) в ext-образе.")
        }
    }

    private static func writeDebugfsFile(
        from sourceURL: URL,
        to destination: String,
        mode: String,
        on device: String,
        reporter: ProgressReporter
    ) throws {
        try requireDebugfsCommand(
            "write \(sourceURL.path) \(destination)",
            on: device,
            writable: true,
            reporter: reporter
        )
        guard try debugfsPathExists(destination, on: device, reporter: reporter) else {
            throw AppError.commandFailed("debugfs не создал \(destination) в ext-образе.")
        }
        for field in ["mode \(mode)", "uid 0", "gid 0"] {
            try requireDebugfsCommand(
                "set_inode_field \(destination) \(field)",
                on: device,
                writable: true,
                reporter: reporter
            )
        }
    }

    private static func removeDebugfsPath(
        _ path: String,
        on device: String,
        reporter: ProgressReporter
    ) throws {
        guard try debugfsPathExists(path, on: device, reporter: reporter) else { return }
        try requireDebugfsCommand(
            "rm \(path)",
            on: device,
            writable: true,
            reporter: reporter
        )
    }

    private static func debugfsPathExists(
        _ path: String,
        on device: String,
        reporter: ProgressReporter
    ) throws -> Bool {
        let result = try runDebugfs("stat \(path)", on: device, reporter: reporter)
        let combined = result.output + "\n" + result.error
        if combined.localizedCaseInsensitiveContains("file not found") ||
            combined.localizedCaseInsensitiveContains("not found by ext2_lookup") {
            return false
        }
        guard result.status == 0 else {
            throw toolFailure("debugfs не смог проверить \(path)", result)
        }
        return result.output.contains("Inode:")
    }

    private static func debugfsContents(
        of path: String,
        on device: String,
        reporter: ProgressReporter
    ) throws -> String {
        let result = try runDebugfs("cat \(path)", on: device, reporter: reporter)
        guard result.status == 0 else {
            throw toolFailure("debugfs не смог прочитать \(path)", result)
        }
        return result.output
    }

    private static func requireDebugfsCommand(
        _ command: String,
        on device: String,
        writable: Bool = true,
        reporter: ProgressReporter
    ) throws {
        let result = try runDebugfs(
            command,
            on: device,
            writable: writable,
            reporter: reporter
        )
        let combined = result.output + "\n" + result.error
        let failed = [
            "file not found", "not found by ext2_lookup", "usage:",
            "invalid field", "command not found", "filesystem is read-only"
        ].contains { combined.localizedCaseInsensitiveContains($0) }
        guard result.status == 0, !failed else {
            throw toolFailure("debugfs не выполнил команду для ext-образа", result)
        }
    }

    private static func runDebugfs(
        _ command: String,
        on device: String,
        writable: Bool = false,
        reporter: ProgressReporter
    ) throws -> ToolResult {
        var arguments: [String] = []
        if writable { arguments.append("-w") }
        arguments += ["-R", command, device]
        return try runTool(
            executable: try requiredTool("debugfs"),
            arguments: arguments,
            reporter: reporter
        )
    }

    private static func collectFreeBlockRanges(
        _ device: String,
        geometry: FileSystemGeometry,
        partitionOffset: UInt64,
        reporter: ProgressReporter
    ) throws -> [SparseRange] {
        guard geometry.freeBlockCount > 0 else { return [] }
        guard geometry.freeBlockCount <= UInt64.max / geometry.blockSize else {
            throw AppError.commandFailed("Переполнение при вычислении свободного места ext-раздела.")
        }

        let identifier = UUID().uuidString
        let sourceURL = URL(fileURLWithPath: "/tmp/sd-archiver-zero-\(identifier).bin")
        let temporaryPath = "/.sd-archiver-zero-\(identifier)"
        try createNonzeroFile(
            at: sourceURL,
            size: geometry.freeBlockCount * geometry.blockSize,
            reporter: reporter
        )
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let writeResult = try runDebugfs(
            "write \(sourceURL.path) \(temporaryPath)",
            on: device,
            writable: true,
            reporter: reporter
        )
        let writeDetails = writeResult.output + "\n" + writeResult.error
        let expectedNoSpace = writeDetails.localizedCaseInsensitiveContains("could not allocate block") ||
            writeDetails.localizedCaseInsensitiveContains("no space left")
        guard writeResult.status == 0 || expectedNoSpace,
              try debugfsPathExists(temporaryPath, on: device, reporter: reporter) else {
            throw toolFailure("Не удалось заполнить свободные блоки ext", writeResult)
        }

        var shouldRemoveTemporaryFile = true
        defer {
            if shouldRemoveTemporaryFile {
                try? removeDebugfsPath(temporaryPath, on: device, reporter: reporter)
            }
        }

        let blocksResult = try runDebugfs(
            "blocks \(temporaryPath)",
            on: device,
            reporter: reporter
        )
        guard blocksResult.status == 0 else {
            throw toolFailure("debugfs не смог перечислить свободные блоки ext", blocksResult)
        }
        let blockNumbers = blocksResult.output
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { UInt64($0) }
            .filter { $0 < geometry.blockCount }
        guard !blockNumbers.isEmpty else {
            throw AppError.commandFailed("debugfs не сообщил блоки временного файла очистки.")
        }

        try removeDebugfsPath(temporaryPath, on: device, reporter: reporter)
        shouldRemoveTemporaryFile = false
        return sparseRanges(
            for: blockNumbers,
            blockSize: geometry.blockSize,
            partitionOffset: partitionOffset
        )
    }

    private static func createNonzeroFile(
        at url: URL,
        size: UInt64,
        reporter: ProgressReporter
    ) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw AppError.commandFailed("Не удалось создать временный файл очистки ext.")
        }
        let handle = try FileHandle(forWritingTo: url)
        do {
            let chunk = Data(repeating: 0xA5, count: 4 * 1024 * 1024)
            var written: UInt64 = 0
            while written < size {
                try reporter.checkCancellation()
                let count = Int(min(UInt64(chunk.count), size - written))
                try PosixIO.writeAll(count == chunk.count ? chunk : Data(chunk.prefix(count)), to: handle)
                written += UInt64(count)
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private static func sparseRanges(
        for blocks: [UInt64],
        blockSize: UInt64,
        partitionOffset: UInt64
    ) -> [SparseRange] {
        let sorted = Array(Set(blocks)).sorted()
        guard let first = sorted.first else { return [] }
        var runStart = first
        var previous = first
        var ranges: [SparseRange] = []

        func appendRange(start: UInt64, end: UInt64) {
            ranges.append(
                SparseRange(
                    offset: partitionOffset + start * blockSize,
                    length: (end - start + 1) * blockSize
                )
            )
        }

        for block in sorted.dropFirst() {
            if block == previous + 1 {
                previous = block
            } else {
                appendRange(start: runStart, end: previous)
                runStart = block
                previous = block
            }
        }
        appendRange(start: runStart, end: previous)
        return ranges
    }

    private static func runFileSystemCheck(
        _ device: String,
        reporter: ProgressReporter
    ) throws {
        let result = try runTool(
            executable: try requiredTool("e2fsck"),
            arguments: ["-f", "-p", device],
            reporter: reporter
        )
        if result.status == 0 || result.status == 1 { return }

        // Only the temporary image is repaired; the source device remains read-only.
        if result.status & 4 != 0 {
            let repair = try runTool(
                executable: try requiredTool("e2fsck"),
                arguments: ["-f", "-y", device],
                reporter: reporter
            )
            guard repair.status == 0 || repair.status == 1 else {
                throw toolFailure("Не удалось исправить временную копию ext-раздела", repair)
            }
            return
        }
        throw toolFailure("Проверка ext-раздела не пройдена", result)
    }

    private static func minimumBlockCount(
        _ device: String,
        reporter: ProgressReporter
    ) throws -> UInt64 {
        let result = try runTool(
            executable: try requiredTool("resize2fs"),
            arguments: ["-P", device],
            reporter: reporter
        )
        guard result.status == 0 else {
            throw toolFailure("resize2fs не смог определить минимальный размер", result)
        }
        let combined = result.output + "\n" + result.error
        guard let value = firstCapture(
            pattern: #"minimum size of the filesystem:\s*([0-9]+)"#,
            in: combined
        ).flatMap(UInt64.init) else {
            throw AppError.commandFailed("Не удалось разобрать минимальный размер из ответа resize2fs.")
        }
        return value
    }

    private static func fileSystemGeometry(
        _ device: String,
        reporter: ProgressReporter
    ) throws -> FileSystemGeometry {
        let result = try runTool(
            executable: try requiredTool("tune2fs"),
            arguments: ["-l", device],
            reporter: reporter
        )
        guard result.status == 0 else {
            throw toolFailure("tune2fs не смог прочитать параметры ext-раздела", result)
        }
        let combined = result.output + "\n" + result.error
        guard let blockCount = firstCapture(pattern: #"(?m)^Block count:\s*([0-9]+)"#, in: combined).flatMap(UInt64.init),
              let blockSize = firstCapture(pattern: #"(?m)^Block size:\s*([0-9]+)"#, in: combined).flatMap(UInt64.init),
              let freeBlockCount = firstCapture(pattern: #"(?m)^Free blocks:\s*([0-9]+)"#, in: combined).flatMap(UInt64.init),
              blockCount > 0,
              blockSize >= 1024,
              freeBlockCount <= blockCount else {
            throw AppError.commandFailed("Не удалось разобрать геометрию файловой системы из ответа tune2fs.")
        }
        return FileSystemGeometry(
            blockCount: blockCount,
            blockSize: blockSize,
            freeBlockCount: freeBlockCount
        )
    }

    private static func updateMBRAndTruncate(
        imageURL: URL,
        plan: ExtShrinkPlan,
        newSectorCount: UInt64
    ) throws -> UInt64 {
        guard plan.firstLBA <= UInt64.max - newSectorCount else {
            throw AppError.commandFailed("Переполнение при вычислении размера образа.")
        }
        let newSize = (plan.firstLBA + newSectorCount) * 512
        let handle = try FileHandle(forUpdating: imageURL)
        defer { try? handle.close() }

        var mbr = try PosixIO.readExact(from: handle, offset: 0, count: 512)
        let entryOffset = 446 + plan.partitionIndex * 16
        guard UInt64(mbr.littleUInt32(at: entryOffset + 8) ?? 0) == plan.firstLBA,
              UInt64(mbr.littleUInt32(at: entryOffset + 12) ?? 0) == plan.sectorCount else {
            throw AppError.commandFailed("Таблица MBR временного образа неожиданно изменилась.")
        }

        mbr.setLittleUInt32(UInt32(newSectorCount), at: entryOffset + 12)
        try PosixIO.writeExact(mbr, to: handle, offset: 0)
        guard Darwin.ftruncate(handle.fileDescriptor, off_t(newSize)) == 0 else {
            let code = errno
            throw AppError.commandFailed(
                "Не удалось обрезать временный образ: \(String(cString: strerror(code))) (errno \(code))."
            )
        }
        try handle.synchronize()
        return newSize
    }

    private static func runTool(
        executable: String,
        arguments: [String],
        reporter: ProgressReporter?
    ) throws -> ToolResult {
        let identifier = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
        let outputURL = directory.appendingPathComponent("sd-shrink-\(identifier).out")
        let errorURL = directory.appendingPathComponent("sd-shrink-\(identifier).err")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        do {
            try process.run()
            while process.isRunning {
                do {
                    try reporter?.checkCancellation()
                } catch {
                    process.terminate()
                    process.waitUntilExit()
                    throw error
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
            process.waitUntilExit()
        } catch {
            try? outputHandle.close()
            try? errorHandle.close()
            throw error
        }

        try outputHandle.close()
        try errorHandle.close()
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        let error = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
        return ToolResult(status: process.terminationStatus, output: output, error: error)
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func toolFailure(_ prefix: String, _ result: ToolResult) -> AppError {
        let details = [result.error, result.output]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let suffix = details.isEmpty ? "" : " \(details)"
        return AppError.commandFailed("\(prefix) (код \(result.status)).\(suffix)")
    }

    private static func unsupported(_ reason: String) -> AppError {
        AppError.invalidArguments(
            "Уменьшение доступно для последнего основного раздела ext2/3/4 в MBR. \(reason) Отключите «Уменьшить ext» или создайте обычный образ."
        )
    }

    private static let autoExpandScript = """
    #!/bin/sh
    # SD_ARCHIVER_AUTOEXPAND
    set -eu

    ROOT_SOURCE="$(findmnt -n -o SOURCE /)"
    ROOT_PART="$(readlink -f "$ROOT_SOURCE")"
    PART_NUMBER="$(lsblk -n -o PARTN "$ROOT_PART" | tr -d '[:space:]')"
    PARENT_NAME="$(lsblk -n -o PKNAME "$ROOT_PART" | tr -d '[:space:]')"
    [ -n "$PART_NUMBER" ]
    [ -n "$PARENT_NAME" ]
    PARENT_DEVICE="/dev/$PARENT_NAME"

    if command -v growpart >/dev/null 2>&1; then
        growpart "$PARENT_DEVICE" "$PART_NUMBER" || true
    elif command -v raspi-config >/dev/null 2>&1; then
        raspi-config --expand-rootfs || true
    elif command -v parted >/dev/null 2>&1; then
        parted -s "$PARENT_DEVICE" resizepart "$PART_NUMBER" 100% || true
    else
        exit 1
    fi

    command -v partprobe >/dev/null 2>&1 && partprobe "$PARENT_DEVICE" || true
    command -v udevadm >/dev/null 2>&1 && udevadm settle || true
    resize2fs "$ROOT_PART"

    systemctl disable sd-archiver-grow-rootfs.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/multi-user.target.wants/sd-archiver-grow-rootfs.service
    rm -f /etc/systemd/system/sd-archiver-grow-rootfs.service
    rm -f /usr/local/sbin/sd-archiver-grow-rootfs
    systemctl daemon-reload >/dev/null 2>&1 || true
    """

    private static let autoExpandService = """
    [Unit]
    Description=Expand the root filesystem after restoring an SD Archiver image
    After=local-fs.target
    ConditionPathExists=/usr/local/sbin/sd-archiver-grow-rootfs

    [Service]
    Type=oneshot
    ExecStart=/usr/local/sbin/sd-archiver-grow-rootfs

    [Install]
    WantedBy=multi-user.target
    """

    private struct FileSystemGeometry {
        let blockCount: UInt64
        let blockSize: UInt64
        let freeBlockCount: UInt64
    }

    private struct ToolResult {
        let status: Int32
        let output: String
        let error: String
    }
}

private extension UInt64 {
    func addingClamped(_ value: UInt64) -> UInt64 {
        let (result, overflow) = addingReportingOverflow(value)
        return overflow ? .max : result
    }
}

private extension Data {
    mutating func setLittleUInt32(_ value: UInt32, at offset: Int) {
        guard offset >= 0, offset + 4 <= count else { return }
        for byteOffset in 0..<4 {
            let index = self.index(startIndex, offsetBy: offset + byteOffset)
            self[index] = UInt8((value >> UInt32(byteOffset * 8)) & 0xFF)
        }
    }
}
