import CryptoKit
import Foundation

enum VerificationOutcome: Equatable {
    case verified
    case skipped
}

enum WrittenMediaVerifier {
    static func verify(
        handle: FileHandle,
        totalSize: UInt64,
        expectedSHA256: String,
        reporter: ProgressReporter,
        message: String,
        prematureReadMessage: String,
        mismatchMessage: String,
        chunkSize: Int = 4 * 1024 * 1024
    ) throws -> VerificationOutcome {
        reporter.update(
            phase: .verifyingCard,
            processed: 0,
            total: totalSize,
            message: message,
            force: true
        )

        guard !reporter.shouldSkipVerification else { return .skipped }

        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        var processed: UInt64 = 0

        while processed < totalSize {
            try reporter.checkCancellation()
            if reporter.shouldSkipVerification { return .skipped }

            let amount = min(chunkSize, Int(totalSize - processed))
            let data = try PosixIO.readBlock(from: handle, count: amount)
            guard !data.isEmpty else {
                throw AppError.commandFailed(prematureReadMessage)
            }

            hasher.update(data: data)
            processed += UInt64(data.count)
            reporter.update(
                phase: .verifyingCard,
                processed: processed,
                total: totalSize,
                message: message
            )
        }

        // The signal can arrive after the final block but before digest comparison.
        guard !reporter.shouldSkipVerification else { return .skipped }

        let actualSHA256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualSHA256 == expectedSHA256 else {
            throw AppError.archiveInvalid(mismatchMessage)
        }
        return .verified
    }
}
