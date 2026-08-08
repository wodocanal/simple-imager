import Foundation

enum PosixIOSmokeError: Error {
    case failed(String)
}

@main
struct PosixIOSmoke {
    static func main() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("simple-imager-posix-\(UUID().uuidString)")
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = Data((0..<(2 * 1024 * 1024)).map { UInt8($0 % 251) })
        let writer = try FileHandle(forWritingTo: url)
        try PosixIO.writeAll(expected, to: writer)
        try writer.close()

        let reader = try FileHandle(forReadingFrom: url)
        let block = try PosixIO.readBlock(from: reader, count: expected.count + 4096)
        guard block == expected else {
            throw PosixIOSmokeError.failed("sequential POSIX read/write changed data")
        }

        let slice = try PosixIO.readExact(from: reader, offset: 65_537, count: 512 * 1024)
        guard slice == expected.subdata(in: 65_537..<(65_537 + 512 * 1024)) else {
            throw PosixIOSmokeError.failed("positioned POSIX read returned wrong data")
        }
        try reader.close()

        print("POSIX I/O smoke test passed (large sequential and positioned blocks).")
    }
}
