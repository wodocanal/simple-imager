import Foundation

struct DiskInfo: Identifiable, Hashable, Codable {
    let identifier: String
    let mediaName: String
    let size: UInt64
    let isInternal: Bool
    let isRemovable: Bool
    let isWhole: Bool
    let isPhysical: Bool

    var id: String { identifier }
    var devicePath: String { "/dev/\(identifier)" }
    var rawDevicePath: String { "/dev/r\(identifier)" }

    var displayName: String {
        "\(mediaName) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .decimal))"
    }
}

enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    case compact
    case compatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "Компактный"
        case .compatible: "Совместимый"
        }
    }

    var explanation: String {
        switch self {
        case .compact:
            "Неиспользуемые кластеры FAT32/exFAT превращаются в нули в потоке образа. Исходная карта не изменяется."
        case .compatible:
            "Читается каждый сектор карты. Свободное место сожмется только в том случае, если в нем уже находятся нули."
        }
    }
}

struct ImageManifest: Codable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let createdAt: Date
    let sourceDevice: String
    let sourceMediaName: String
    let sourceSize: UInt64
    let imageFileName: String
    let compression: String
    let compressionLevel: Int
    let sha256: String
    let captureMode: CaptureMode
    let compactedFileSystems: [String]
    let rawPartitions: [String]
}

enum JobPhase: String, Codable {
    case preparing
    case analyzing
    case reading
    case verifyingArchive
    case writing
    case verifyingCard
    case finalizing
    case completed
    case cancelled
    case failed

    var title: String {
        switch self {
        case .preparing: "Подготовка"
        case .analyzing: "Анализ разделов"
        case .reading: "Чтение и сжатие"
        case .verifyingArchive: "Проверка архива"
        case .writing: "Запись карты"
        case .verifyingCard: "Проверка записи"
        case .finalizing: "Завершение"
        case .completed: "Готово"
        case .cancelled: "Отменено"
        case .failed: "Ошибка"
        }
    }
}

struct JobProgress: Codable {
    let phase: JobPhase
    let processedBytes: UInt64
    let totalBytes: UInt64
    let message: String

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(processedBytes) / Double(totalBytes))
    }
}

enum OperationKind: String, CaseIterable, Identifiable {
    case create
    case restore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .create: "Создать образ"
        case .restore: "Записать карту"
        }
    }
}

enum AppError: LocalizedError {
    case commandFailed(String)
    case invalidResponse(String)
    case unsafeDisk(String)
    case invalidArguments(String)
    case cancelled
    case helperFailed(String)
    case archiveInvalid(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message),
             .invalidResponse(let message),
             .unsafeDisk(let message),
             .invalidArguments(let message),
             .helperFailed(let message),
             .archiveInvalid(let message):
            message
        case .cancelled:
            "Операция отменена."
        }
    }
}
