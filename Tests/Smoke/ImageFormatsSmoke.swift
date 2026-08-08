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

        let magicURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("simple-imager-magic-\(UUID().uuidString).img.gz")
        defer { try? FileManager.default.removeItem(at: magicURL) }
        try Data([0x28, 0xB5, 0x2F, 0xFD, 0x00]).write(to: magicURL)
        guard ImageFileFormat.detect(url: magicURL)?.compression == .zstd else {
            throw FormatSmokeError.failed("content signature did not override the extension")
        }

        L10n.configure(.english)
        guard L10n.text("Записать образ") == "Flash image" else {
            throw FormatSmokeError.failed("English localization is unavailable")
        }
        L10n.configure(.russian)
        guard L10n.text("Записать образ") == "Записать образ" else {
            throw FormatSmokeError.failed("Russian localization is unavailable")
        }
        L10n.configure(.english)

        print("Image format and localization smoke test passed.")
    }
}

private enum FormatSmokeError: Error {
    case failed(String)
}
