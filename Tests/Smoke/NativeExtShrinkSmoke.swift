import Foundation

@main
enum NativeExtShrinkSmoke {
    static func main() throws {
        guard NativeExtImageShrinker.isAvailable else {
            throw SmokeError.failed(NativeExtImageShrinker.dependencyMessage ?? "e2fsprogs is unavailable")
        }

        let originalSize = UInt64(384 * 1024 * 1024)
        let firstLBA = UInt32(2048)
        let sectorCount = UInt32(originalSize / 512 - UInt64(firstLBA))
        let partitionOffset = UInt64(firstLBA) * 512
        let blockCount = (UInt64(sectorCount) * 512) / 4096
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-ext-shrink-\(UUID().uuidString)", isDirectory: true)
        let imageURL = directory.appendingPathComponent("source.img")
        let rootURL = directory.appendingPathComponent("root", isDirectory: true)
        let progressURL = directory.appendingPathComponent("progress.json")
        let cancelURL = directory.appendingPathComponent("cancel")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("etc/systemd/system/multi-user.target.wants", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("usr/local/sbin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("NAME=Smoke Linux\n".utf8).write(
            to: rootURL.appendingPathComponent("etc/os-release")
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = FileManager.default.createFile(atPath: imageURL.path, contents: nil)
        let writer = try FileHandle(forWritingTo: imageURL)
        let dirtyChunk = Data(repeating: 0xA5, count: 4 * 1024 * 1024)
        var dirtyBytes: UInt64 = 0
        while dirtyBytes < originalSize {
            let count = Int(min(UInt64(dirtyChunk.count), originalSize - dirtyBytes))
            try PosixIO.writeAll(
                count == dirtyChunk.count ? dirtyChunk : Data(dirtyChunk.prefix(count)),
                to: writer
            )
            dirtyBytes += UInt64(count)
        }
        var mbr = Data(repeating: 0, count: 512)
        mbr[446 + 4] = 0x83
        mbr.writeLittleUInt32(firstLBA, at: 446 + 8)
        mbr.writeLittleUInt32(sectorCount, at: 446 + 12)
        mbr[510] = 0x55
        mbr[511] = 0xAA
        try PosixIO.writeExact(mbr, to: writer, offset: 0)
        try writer.close()

        let makeFileSystem = try run(
            "/opt/homebrew/opt/e2fsprogs/sbin/mke2fs",
            [
                "-q", "-t", "ext4", "-F", "-b", "4096",
                "-E", "offset=\(partitionOffset)",
                "-d", rootURL.path,
                imageURL.path, String(blockCount)
            ]
        )
        guard makeFileSystem.status == 0 else {
            throw SmokeError.failed("mke2fs failed: \(makeFileSystem.output)")
        }

        let attachment = try run(
            "/usr/bin/hdiutil",
            [
                "attach", "-nomount", "-noverify",
                "-imagekey", "diskimage-class=CRawDiskImage",
                imageURL.path
            ]
        )
        guard attachment.status == 0,
              let wholeDevice = attachment.output
                .split(whereSeparator: \Character.isNewline)
                .compactMap({ $0.split(whereSeparator: \Character.isWhitespace).first.map(String.init) })
                .first(where: {
                    $0.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil
                }) else {
            throw SmokeError.failed("hdiutil attach failed: \(attachment.output)")
        }
        var isAttached = true
        defer {
            if isAttached { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", wholeDevice]) }
        }

        let rawDevice = wholeDevice.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        let reader = try FileHandle(forReadingFrom: URL(fileURLWithPath: rawDevice))
        PosixIO.configureSequentialDevice(reader)
        let plan = try NativeExtImageShrinker.analyze(handle: reader, diskSize: originalSize)
        try reader.close()
        let detach = try run("/usr/bin/hdiutil", ["detach", "-force", wholeDevice])
        guard detach.status == 0 else {
            throw SmokeError.failed("hdiutil detach failed: \(detach.output)")
        }
        isAttached = false

        let reporter = ProgressReporter(progressURL: progressURL, cancelURL: cancelURL)
        let shrinkResult = try NativeExtImageShrinker.shrink(
            imageURL: imageURL,
            plan: plan,
            autoExpand: true,
            reporter: reporter
        )
        let reducedSize = shrinkResult.logicalSize
        guard shrinkResult.autoExpandStatus == .installed else {
            throw SmokeError.failed("auto-expansion service was not installed")
        }

        guard reducedSize < originalSize / 2 else {
            throw SmokeError.failed("image was not reduced enough: \(reducedSize) of \(originalSize)")
        }
        let finalReader = try FileHandle(forReadingFrom: imageURL)
        defer { try? finalReader.close() }
        let finalPlan = try NativeExtImageShrinker.analyze(handle: finalReader, diskSize: reducedSize)
        guard finalPlan.sectorCount < plan.sectorCount else {
            throw SmokeError.failed("MBR partition length was not reduced")
        }
        try finalReader.close()

        let finalAttachment = try run(
            "/usr/bin/hdiutil",
            [
                "attach", "-nomount", "-noverify",
                "-imagekey", "diskimage-class=CRawDiskImage",
                imageURL.path
            ]
        )
        guard finalAttachment.status == 0,
              let finalWholeDevice = parsedWholeDevice(from: finalAttachment.output) else {
            throw SmokeError.failed("final hdiutil attach failed: \(finalAttachment.output)")
        }
        var finalIsAttached = true
        defer {
            if finalIsAttached {
                _ = try? run("/usr/bin/hdiutil", ["detach", "-force", finalWholeDevice])
            }
        }
        let finalPartition = finalWholeDevice + "s\(finalPlan.partitionIndex + 1)"
        let debugfs = "/opt/homebrew/opt/e2fsprogs/sbin/debugfs"
        let script = try run(debugfs, ["-R", "cat /usr/local/sbin/sd-archiver-grow-rootfs", finalPartition])
        guard script.status == 0, script.output.contains("SD_ARCHIVER_AUTOEXPAND") else {
            throw SmokeError.failed("auto-expansion script is missing: \(script.output)")
        }
        let service = try run(debugfs, ["-R", "cat /etc/systemd/system/sd-archiver-grow-rootfs.service", finalPartition])
        guard service.status == 0, service.output.contains("WantedBy=multi-user.target") else {
            throw SmokeError.failed("auto-expansion service is missing: \(service.output)")
        }
        let unused = try run(debugfs, ["-R", "dump_unused", finalPartition])
        guard unused.status == 0, !unused.output.contains("Unused block") else {
            throw SmokeError.failed("unused ext blocks still contain nonzero data")
        }
        let finalDetach = try run("/usr/bin/hdiutil", ["detach", "-force", finalWholeDevice])
        guard finalDetach.status == 0 else {
            throw SmokeError.failed("final hdiutil detach failed: \(finalDetach.output)")
        }
        finalIsAttached = false

        try verifyMissingSystemdDoesNotBlockShrink(in: directory)

        print("Native ext shrink smoke test passed (\(originalSize) -> \(reducedSize) bytes).")
    }

    private static func verifyMissingSystemdDoesNotBlockShrink(in directory: URL) throws {
        let size = UInt64(192 * 1024 * 1024)
        let firstLBA = UInt32(2048)
        let sectors = UInt32(size / 512 - UInt64(firstLBA))
        let offset = UInt64(firstLBA) * 512
        let imageURL = directory.appendingPathComponent("without-systemd.img")
        _ = FileManager.default.createFile(atPath: imageURL.path, contents: nil)
        let writer = try FileHandle(forWritingTo: imageURL)
        try writer.truncate(atOffset: size)
        var mbr = Data(repeating: 0, count: 512)
        mbr[446 + 4] = 0x83
        mbr.writeLittleUInt32(firstLBA, at: 446 + 8)
        mbr.writeLittleUInt32(sectors, at: 446 + 12)
        mbr[510] = 0x55
        mbr[511] = 0xAA
        try PosixIO.writeExact(mbr, to: writer, offset: 0)
        try writer.close()

        let makeFileSystem = try run(
            "/opt/homebrew/opt/e2fsprogs/sbin/mke2fs",
            [
                "-q", "-t", "ext4", "-F", "-b", "4096",
                "-E", "offset=\(offset)",
                imageURL.path, String((UInt64(sectors) * 512) / 4096)
            ]
        )
        guard makeFileSystem.status == 0 else {
            throw SmokeError.failed("secondary mke2fs failed: \(makeFileSystem.output)")
        }

        let reader = try FileHandle(forReadingFrom: imageURL)
        let plan = try NativeExtImageShrinker.analyze(handle: reader, diskSize: size)
        try reader.close()
        let reporter = ProgressReporter(
            progressURL: directory.appendingPathComponent("without-systemd.progress.json"),
            cancelURL: directory.appendingPathComponent("without-systemd.cancel")
        )
        let result = try NativeExtImageShrinker.shrink(
            imageURL: imageURL,
            plan: plan,
            autoExpand: true,
            reporter: reporter
        )
        guard result.autoExpandStatus == .systemdUnavailable else {
            throw SmokeError.failed("missing systemd was not reported correctly")
        }
    }

    private static func parsedWholeDevice(from output: String) -> String? {
        output
            .split(whereSeparator: \Character.isNewline)
            .compactMap { $0.split(whereSeparator: \Character.isWhitespace).first.map(String.init) }
            .first {
                $0.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil
            }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

private enum SmokeError: Error {
    case failed(String)
}

private extension Data {
    mutating func writeLittleUInt32(_ value: UInt32, at offset: Int) {
        for byte in 0..<4 {
            self[offset + byte] = UInt8((value >> UInt32(byte * 8)) & 0xFF)
        }
    }
}
