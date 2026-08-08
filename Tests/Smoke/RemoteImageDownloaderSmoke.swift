import Foundation

@main
enum RemoteImageDownloaderSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2,
              let remoteURL = URL(string: CommandLine.arguments[1]) else {
            throw SmokeError.failed("expected one HTTP URL")
        }
        guard RemoteImageDownloader.validatedURL(from: remoteURL.absoluteString) != nil,
              RemoteImageDownloader.validatedURL(from: "file:///tmp/card.img") == nil,
              RemoteImageDownloader.validatedURL(from: "https://user:pass@example.com/card.img") == nil else {
            throw SmokeError.failed("URL safety validation failed")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-download-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try RemoteImageDownloader.download(
            from: remoteURL,
            to: directory.appendingPathComponent("downloaded.remote"),
            cancelURL: directory.appendingPathComponent("cancel")
        )
        guard result.format == ImageFileFormat(rawType: .img, compression: .zstd) else {
            throw SmokeError.failed("remote format was not detected")
        }
        let size = (try FileManager.default.attributesOfItem(atPath: result.fileURL.path)[.size] as? NSNumber)?.uint64Value
        guard size == 1024 * 1024 else {
            throw SmokeError.failed("downloaded file size is incorrect")
        }
        print("Remote image downloader smoke test passed.")
    }
}

private enum SmokeError: Error {
    case failed(String)
}
