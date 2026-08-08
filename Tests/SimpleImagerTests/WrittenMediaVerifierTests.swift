import CryptoKit
import Foundation
import XCTest
@testable import SimpleImager

final class WrittenMediaVerifierTests: XCTestCase {
    func testVerifiesMatchingData() throws {
        let fixture = try makeFixture(data: Data("written image".utf8))
        defer { fixture.cleanup() }

        let result = try WrittenMediaVerifier.verify(
            handle: fixture.handle,
            totalSize: UInt64(fixture.data.count),
            expectedSHA256: digest(fixture.data),
            reporter: fixture.reporter,
            message: "verify",
            prematureReadMessage: "short read",
            mismatchMessage: "mismatch",
            chunkSize: 3
        )

        XCTAssertEqual(result, .verified)
    }

    func testSkipSignalIsSuccessfulOutcome() throws {
        let fixture = try makeFixture(data: Data("written image".utf8))
        defer { fixture.cleanup() }
        try Data("skip".utf8).write(to: fixture.skipURL)

        let result = try WrittenMediaVerifier.verify(
            handle: fixture.handle,
            totalSize: UInt64(fixture.data.count),
            expectedSHA256: digest(Data("different data".utf8)),
            reporter: fixture.reporter,
            message: "verify",
            prematureReadMessage: "short read",
            mismatchMessage: "mismatch",
            chunkSize: 3
        )

        XCTAssertEqual(result, .skipped)
    }

    func testRejectsMismatchingData() throws {
        let fixture = try makeFixture(data: Data("written image".utf8))
        defer { fixture.cleanup() }

        XCTAssertThrowsError(
            try WrittenMediaVerifier.verify(
                handle: fixture.handle,
                totalSize: UInt64(fixture.data.count),
                expectedSHA256: digest(Data("different data".utf8)),
                reporter: fixture.reporter,
                message: "verify",
                prematureReadMessage: "short read",
                mismatchMessage: "mismatch",
                chunkSize: 3
            )
        )
    }

    private func makeFixture(data: Data) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("written-media-verifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mediaURL = directory.appendingPathComponent("media.raw")
        try data.write(to: mediaURL)
        let skipURL = directory.appendingPathComponent("skip")
        return Fixture(
            directory: directory,
            data: data,
            handle: try FileHandle(forReadingFrom: mediaURL),
            skipURL: skipURL,
            reporter: ProgressReporter(
                progressURL: directory.appendingPathComponent("progress.json"),
                cancelURL: directory.appendingPathComponent("cancel"),
                skipVerificationURL: skipURL
            )
        )
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct Fixture {
    let directory: URL
    let data: Data
    let handle: FileHandle
    let skipURL: URL
    let reporter: ProgressReporter

    func cleanup() {
        try? handle.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
