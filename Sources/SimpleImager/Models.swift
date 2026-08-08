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

enum ImageProcessingMode: String, Codable, CaseIterable, Identifiable {
    case exact
    case optimizeFreeSpace
    case shrinkExt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exact: "Без изменений"
        case .optimizeFreeSpace: "Обнулить пустоты"
        case .shrinkExt: "Уменьшить образ"
        }
    }

    var explanation: String {
        switch self {
        case .exact:
            "Каждый сектор сохраняется без изменений, включая содержимое свободного места."
        case .optimizeFreeSpace:
            "Неиспользуемые кластеры FAT32/exFAT превращаются в нули. Несжатые образы сохраняются разреженными и занимают меньше места на диске."
        case .shrinkExt:
            "Последний основной раздел ext2/3/4 и логический размер MBR-образа уменьшаются, а свободные блоки зануляются."
        }
    }

    var optimizesFreeSpace: Bool { self == .optimizeFreeSpace }
    var shrinksExt: Bool { self == .shrinkExt }
}

enum RestoreSourceKind: String, CaseIterable, Identifiable {
    case file
    case url
    case drive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .file: "Из файла"
        case .url: "По URL"
        case .drive: "Клонировать"
        }
    }

    var icon: String {
        switch self {
        case .file: "doc.fill"
        case .url: "link"
        case .drive: "externaldrive.fill.badge.plus"
        }
    }
}

enum JobPhase: String, Codable {
    case preparing
    case downloading
    case analyzing
    case reading
    case shrinking
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
        case .downloading: "Загрузка образа"
        case .analyzing: "Анализ разделов"
        case .reading: "Создание образа"
        case .shrinking: "Уменьшение образа"
        case .verifyingArchive: "Проверка образа"
        case .writing: "Запись образа"
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
        case .create: "Считать образ"
        case .restore: "Записать образ"
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
