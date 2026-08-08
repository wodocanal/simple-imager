import Foundation

@main
enum ImageFormatsSmoke {
    static func main() throws {
        for rawType in RawImageType.allCases {
            for compression in ImageCompression.allCases {
                let expected = ImageFileFormat(rawType: rawType, compression: compression)
                let url = URL(fileURLWithPath: "/tmp/image.\(expected.fileSuffix)")
                guard ImageFileFormat.detect(url: url) == expected else {
                    throw FormatSmokeError.failed("failed to detect \(expected.fileSuffix)")
                }
            }
        }

        let renamed = ImageFileFormat(rawType: .raw, compression: .gzip)
            .applying(to: URL(fileURLWithPath: "/tmp/card.img.zst"))
        guard renamed.lastPathComponent == "card.raw.gz" else {
            throw FormatSmokeError.failed("supported suffix was not replaced")
        }

        guard ImageFileFormat.detect(url: URL(fileURLWithPath: "/tmp/card.iso")) == nil else {
            throw FormatSmokeError.failed("ISO must remain unsupported")
        }

        print("Image format smoke test passed (24 combinations and unsupported formats).")
    }
}

private enum FormatSmokeError: Error {
    case failed(String)
}
