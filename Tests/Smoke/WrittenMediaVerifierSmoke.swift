import CryptoKit
import Foundation

@main
enum WrittenMediaVerifierSmoke {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("written-media-verifier-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let data = Data("written image".utf8)
        let mediaURL = directory.appendingPathComponent("media.raw")
        try data.write(to: mediaURL)
        let skipURL = directory.appendingPathComponent("skip")
        let reporter = ProgressReporter(
            progressURL: directory.appendingPathComponent("progress.json"),
            cancelURL: directory.appendingPathComponent("cancel"),
            skipVerificationURL: skipURL
        )

        let matchingHandle = try FileHandle(forReadingFrom: mediaURL)
        let verified = try WrittenMediaVerifier.verify(
            handle: matchingHandle,
            totalSize: UInt64(data.count),
            expectedSHA256: digest(data),
            reporter: reporter,
            message: "verify",
            prematureReadMessage: "short read",
            mismatchMessage: "mismatch",
            chunkSize: 3
        )
        try matchingHandle.close()
        guard verified == .verified else {
            throw SmokeError.failed("matching data was not verified")
        }

        try Data("skip".utf8).write(to: skipURL)
        let skippedHandle = try FileHandle(forReadingFrom: mediaURL)
        let skipped = try WrittenMediaVerifier.verify(
            handle: skippedHandle,
            totalSize: UInt64(data.count),
            expectedSHA256: digest(Data("different data".utf8)),
            reporter: reporter,
            message: "verify",
            prematureReadMessage: "short read",
            mismatchMessage: "mismatch",
            chunkSize: 3
        )
        try skippedHandle.close()
        guard skipped == .skipped else {
            throw SmokeError.failed("skip signal was not a successful outcome")
        }

        try FileManager.default.removeItem(at: skipURL)
        let mismatchingHandle = try FileHandle(forReadingFrom: mediaURL)
        defer { try? mismatchingHandle.close() }
        do {
            _ = try WrittenMediaVerifier.verify(
                handle: mismatchingHandle,
                totalSize: UInt64(data.count),
                expectedSHA256: digest(Data("different data".utf8)),
                reporter: reporter,
                message: "verify",
                prematureReadMessage: "short read",
                mismatchMessage: "mismatch",
                chunkSize: 3
            )
            throw SmokeError.failed("mismatching data passed verification")
        } catch AppError.archiveInvalid {
            // Expected.
        }

        print("Written media verifier smoke test passed.")
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum SmokeError: Error {
    case failed(String)
}
