import Foundation

@main
enum ProgressReporterSmoke {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sd-progress-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let skipURL = directory.appendingPathComponent("skip-verification")
        let reporter = ProgressReporter(
            progressURL: directory.appendingPathComponent("progress.json"),
            cancelURL: directory.appendingPathComponent("cancel"),
            skipVerificationURL: skipURL
        )

        guard !reporter.shouldSkipVerification else {
            throw ReporterSmokeError.failed("verification was skipped before a signal existed")
        }
        try Data("skip".utf8).write(to: skipURL)
        guard reporter.shouldSkipVerification else {
            throw ReporterSmokeError.failed("verification skip signal was not detected")
        }

        print("Progress reporter smoke test passed (verification skip detected).")
    }
}

private enum ReporterSmokeError: Error {
    case failed(String)
}
