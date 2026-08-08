import Foundation

final class ProgressReporter {
    let progressURL: URL
    let cancelURL: URL
    let skipVerificationURL: URL?
    private var lastWrite = Date.distantPast

    init(progressURL: URL, cancelURL: URL, skipVerificationURL: URL? = nil) {
        self.progressURL = progressURL
        self.cancelURL = cancelURL
        self.skipVerificationURL = skipVerificationURL
    }

    var isCancelled: Bool {
        FileManager.default.fileExists(atPath: cancelURL.path)
    }

    var shouldSkipVerification: Bool {
        guard let skipVerificationURL else { return false }
        return FileManager.default.fileExists(atPath: skipVerificationURL.path)
    }

    func update(
        phase: JobPhase,
        processed: UInt64,
        total: UInt64,
        message: String,
        force: Bool = false
    ) {
        let now = Date()
        guard force || now.timeIntervalSince(lastWrite) >= 0.2 else { return }
        lastWrite = now

        let progress = JobProgress(
            phase: phase,
            processedBytes: processed,
            totalBytes: total,
            message: message
        )
        guard let data = try? JSONEncoder().encode(progress) else { return }
        try? data.write(to: progressURL, options: .atomic)
    }

    func checkCancellation() throws {
        if isCancelled { throw AppError.cancelled }
    }
}
