import Foundation

enum RawImageType: String, Codable, CaseIterable, Identifiable {
    case img
    case raw
    case dd

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

enum CodecDirection {
    case encode
    case decode
}

enum ImageCompression: String, Codable, CaseIterable, Identifiable {
    case none
    case zstd
    case gzip
    case xz
    case bzip2
    case lz4
    case zip
    case sevenZip = "7z"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: L10n.text("Без сжатия")
        case .zstd: "Zstandard"
        case .gzip: "gzip"
        case .xz: "XZ"
        case .bzip2: "bzip2"
        case .lz4: "LZ4"
        case .zip: "ZIP"
        case .sevenZip: "7-Zip"
        }
    }

    var shortTitle: String {
        switch self {
        case .none: L10n.text("Нет")
        case .zstd: "ZSTD"
        case .gzip: "GZIP"
        case .xz: "XZ"
        case .bzip2: "BZIP2"
        case .lz4: "LZ4"
        case .zip: "ZIP"
        case .sevenZip: "7Z"
        }
    }

    var fileExtension: String? {
        switch self {
        case .none: nil
        case .zstd: "zst"
        case .gzip: "gz"
        case .xz: "xz"
        case .bzip2: "bz2"
        case .lz4: "lz4"
        case .zip: "zip"
        case .sevenZip: "7z"
        }
    }

    var isArchiveContainer: Bool {
        self == .zip || self == .sevenZip
    }

    func executable(for direction: CodecDirection) -> String? {
        switch self {
        case .none:
            return nil
        case .zstd:
            return RuntimeEnvironment.executable(
                named: "zstd",
                fallbacks: ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
            )
        case .gzip:
            return RuntimeEnvironment.executable(named: "gzip", fallbacks: ["/usr/bin/gzip"])
        case .xz:
            return RuntimeEnvironment.executable(
                named: "xz",
                fallbacks: ["/opt/homebrew/bin/xz", "/usr/local/bin/xz", "/usr/bin/xz"]
            )
        case .bzip2:
            return RuntimeEnvironment.executable(named: "bzip2", fallbacks: ["/usr/bin/bzip2"])
        case .lz4:
            return RuntimeEnvironment.executable(
                named: "lz4",
                fallbacks: ["/opt/homebrew/bin/lz4", "/usr/local/bin/lz4", "/usr/bin/lz4"]
            )
        case .zip:
            let name = direction == .encode ? "zip" : "unzip"
            return RuntimeEnvironment.executable(named: name, fallbacks: ["/usr/bin/\(name)"])
        case .sevenZip:
            let fallbacks = direction == .decode
                ? [
                    "/opt/homebrew/bin/7zz", "/usr/local/bin/7zz",
                    "/opt/homebrew/bin/7z", "/usr/local/bin/7z", "/usr/bin/bsdtar"
                ]
                : [
                    "/opt/homebrew/bin/7zz", "/usr/local/bin/7zz",
                    "/opt/homebrew/bin/7z", "/usr/local/bin/7z"
                ]
            return RuntimeEnvironment.executable(named: "7zz", fallbacks: fallbacks)
        }
    }

    func isAvailable(for direction: CodecDirection) -> Bool {
        self == .none || executable(for: direction) != nil
    }

    var installHint: String? { nil }
}

struct ImageFileFormat: Equatable {
    let rawType: RawImageType
    let compression: ImageCompression

    var fileSuffix: String {
        guard let compressionExtension = compression.fileExtension else {
            return rawType.rawValue
        }
        return "\(rawType.rawValue).\(compressionExtension)"
    }

    var archiveEntryName: String {
        "image.\(rawType.rawValue)"
    }

    func applying(to url: URL) -> URL {
        let originalName = url.lastPathComponent
        let baseName = Self.removingRecognizedSuffix(from: originalName)
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(baseName).\(fileSuffix)")
    }

    static func detect(url: URL) -> ImageFileFormat? {
        detect(fileURL: url, suggestedNames: [url.lastPathComponent])
    }

    static func detect(fileURL: URL, suggestedNames: [String]) -> ImageFileFormat? {
        let namedFormat = suggestedNames.lazy.compactMap(detectByFileName).first
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return namedFormat }

        guard let compression = compressionDetectedFromMagic(at: fileURL) else {
            guard let namedFormat, namedFormat.compression == ImageCompression.none else { return nil }
            return namedFormat
        }
        return ImageFileFormat(rawType: namedFormat?.rawType ?? .img, compression: compression)
    }

    private static func detectByFileName(_ fileName: String) -> ImageFileFormat? {
        let name = fileName.lowercased()

        for rawType in RawImageType.allCases where name.hasSuffix(".\(rawType.rawValue)") {
            return ImageFileFormat(rawType: rawType, compression: .none)
        }

        for compression in ImageCompression.allCases where compression != .none {
            guard let compressionExtension = compression.fileExtension,
                  name.hasSuffix(".\(compressionExtension)") else { continue }
            let stem = String(name.dropLast(compressionExtension.count + 1))
            let rawType = RawImageType.allCases.first { stem.hasSuffix(".\($0.rawValue)") } ?? .img
            return ImageFileFormat(rawType: rawType, compression: compression)
        }

        return nil
    }

    private static func compressionDetectedFromMagic(at url: URL) -> ImageCompression? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 16), !prefix.isEmpty else { return nil }
        let bytes = [UInt8](prefix)

        if bytes.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) { return .zstd }
        if bytes.count >= 4,
           bytes[1] == 0x2A, bytes[2] == 0x4D, bytes[3] == 0x18,
           (0x50...0x5F).contains(bytes[0]) { return .zstd }
        if bytes.starts(with: [0x1F, 0x8B]) { return .gzip }
        if bytes.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if bytes.starts(with: [0x42, 0x5A, 0x68]) { return .bzip2 }
        if bytes.starts(with: [0x04, 0x22, 0x4D, 0x18]) { return .lz4 }
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) ||
            bytes.starts(with: [0x50, 0x4B, 0x05, 0x06]) ||
            bytes.starts(with: [0x50, 0x4B, 0x07, 0x08]) { return .zip }
        if bytes.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }
        return nil
    }

    private static func removingRecognizedSuffix(from name: String) -> String {
        let lowercased = name.lowercased()
        let suffixes = RawImageType.allCases.flatMap { rawType in
            ImageCompression.allCases.map { compression in
                ImageFileFormat(rawType: rawType, compression: compression).fileSuffix
            }
        }
        .sorted { $0.count > $1.count }

        if let suffix = suffixes.first(where: { lowercased.hasSuffix(".\($0)") }) {
            return String(name.dropLast(suffix.count + 1))
        }
        return urlSafeBaseName(name)
    }

    private static func urlSafeBaseName(_ name: String) -> String {
        let value = (name as NSString).deletingPathExtension
        return value.isEmpty ? "disk-image" : value
    }
}
