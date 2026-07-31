import Foundation

@main
enum DiskSafetySmoke {
    static func main() throws {
        let internalDisk = try DiskService.info(for: "disk0")
        guard internalDisk.isInternal, internalDisk.isWhole else {
            throw SafetySmokeError.failed("diskutil properties were parsed incorrectly")
        }

        do {
            _ = try DiskService.requireSafeExternalWholeDisk("disk0")
            throw SafetySmokeError.failed("the internal system disk passed the safety check")
        } catch AppError.unsafeDisk {
            print("Disk safety smoke test passed (internal disk rejected).")
        }
    }
}

private enum SafetySmokeError: Error {
    case failed(String)
}
