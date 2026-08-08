import Darwin
import Foundation

@main
enum SparseImageSmoke {
    static func main() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sd-card-copy-sparse-\(UUID().uuidString).img")
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        var expected = Data(repeating: 0, count: 32 * 1024 * 1024)
        expected.replaceSubrange(0..<(128 * 1024), with: Data(repeating: 0xA5, count: 128 * 1024))
        let middle = 16 * 1024 * 1024
        expected.replaceSubrange(
            middle..<(middle + 128 * 1024),
            with: Data(repeating: 0x5A, count: 128 * 1024)
        )
        let writer = try FileHandle(forWritingTo: url)
        let chunkSize = 4 * 1024 * 1024
        var ranges: [SparseRange] = []
        for start in stride(from: 0, to: expected.count, by: chunkSize) {
            let end = min(start + chunkSize, expected.count)
            let result = try PosixIO.writeSparse(expected.subdata(in: start..<end), to: writer)
            ranges.append(contentsOf: result.ranges)
        }
        try PosixIO.finalizeSparseFile(writer, ranges: ranges)
        try writer.synchronize()
        try writer.close()

        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            throw SparseSmokeError.failed("stat could not inspect the sparse image")
        }
        let logicalSize = Int(information.st_size)
        let allocatedSize = Int(information.st_blocks) * 512
        guard logicalSize == expected.count else {
            throw SparseSmokeError.failed("sparse image has the wrong logical size")
        }
        guard allocatedSize < logicalSize / 2 else {
            throw SparseSmokeError.failed("zero ranges still consume the full file size")
        }
        guard ranges.reduce(0, { $0 + $1.length }) > UInt64(logicalSize / 2) else {
            throw SparseSmokeError.failed("sparse writer did not detect the zero ranges")
        }

        let restored = try Data(contentsOf: url)
        guard restored == expected else {
            throw SparseSmokeError.failed("sparse ranges do not read back as zeroes")
        }

        print("Sparse image smoke test passed (\(logicalSize) logical, \(allocatedSize) allocated).")
    }
}

private enum SparseSmokeError: Error {
    case failed(String)
}
