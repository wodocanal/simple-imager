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
        case .none: "Без сжатия"
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
        case .none: "Нет"
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
        executableCandidates(for: direction)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func isAvailable(for direction: CodecDirection) -> Bool {
        self == .none || executable(for: direction) != nil
    }

    var installHint: String? {
        switch self {
        case .zstd: "brew install zstd"
        case .xz: "brew install xz"
        case .lz4: "brew install lz4"
        case .sevenZip: "brew install sevenzip"
        case .none, .gzip, .bzip2, .zip: nil
        }
    }

    private func executableCandidates(for direction: CodecDirection) -> [String] {
        switch self {
        case .none:
            return []
        case .zstd:
            return ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        case .gzip:
            return ["/usr/bin/gzip"]
        case .xz:
            return ["/opt/homebrew/bin/xz", "/usr/local/bin/xz", "/usr/bin/xz"]
        case .bzip2:
            return ["/usr/bin/bzip2"]
        case .lz4:
            return ["/opt/homebrew/bin/lz4", "/usr/local/bin/lz4", "/usr/bin/lz4"]
        case .zip:
            return direction == .encode ? ["/usr/bin/zip"] : ["/usr/bin/unzip"]
        case .sevenZip:
            if direction == .decode {
                return [
                    "/opt/homebrew/bin/7zz", "/usr/local/bin/7zz",
                    "/opt/homebrew/bin/7z", "/usr/local/bin/7z",
                    "/usr/bin/bsdtar"
                ]
            }
            return [
                "/opt/homebrew/bin/7zz", "/usr/local/bin/7zz",
                "/opt/homebrew/bin/7z", "/usr/local/bin/7z"
            ]
        }
    }
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
        let name = url.lastPathComponent.lowercased()

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
