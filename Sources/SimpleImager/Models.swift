import Foundation

struct DiskInfo: Identifiable, Hashable, Codable {
    let identifier: String
    let mediaName: String
    let size: UInt64
    let registryEntryID: UInt64
    let registryPath: String
    let serialNumber: String?
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

    var identityDescription: String {
        if let serialNumber, !serialNumber.isEmpty {
            return "S/N \(serialNumber)"
        }
        return "IORegistry \(String(registryEntryID, radix: 16).uppercased())"
    }
}

enum ImageProcessingMode: String, Codable, CaseIterable, Identifiable {
    case exact
    case shrinkExt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exact: L10n.text("Без изменений")
        case .shrinkExt: L10n.text("Уменьшить образ")
        }
    }

    var explanation: String {
        switch self {
        case .exact:
            L10n.text("Каждый сектор сохраняется без изменений, включая содержимое свободного места.")
        case .shrinkExt:
            L10n.text("Последний основной раздел ext2/3/4 и логический размер MBR-образа уменьшаются, а свободные блоки зануляются.")
        }
    }

    var shrinksExt: Bool { self == .shrinkExt }
}

enum RestoreSourceKind: String, CaseIterable, Identifiable {
    case file
    case url
    case drive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .file: L10n.text("Из файла")
        case .url: L10n.text("По URL")
        case .drive: L10n.text("Клонировать")
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
    case compressing
    case verifyingArchive
    case writing
    case verifyingCard
    case finalizing
    case completed
    case cancelled
    case failed

    var title: String {
        switch self {
        case .preparing: L10n.text("Подготовка")
        case .downloading: L10n.text("Загрузка образа")
        case .analyzing: L10n.text("Анализ разделов")
        case .reading: L10n.text("Копирование носителя")
        case .shrinking: L10n.text("Уменьшение образа")
        case .compressing: L10n.text("Архивация образа")
        case .verifyingArchive: L10n.text("Проверка образа")
        case .writing: L10n.text("Запись образа")
        case .verifyingCard: L10n.text("Проверка записи")
        case .finalizing: L10n.text("Завершение")
        case .completed: L10n.text("Готово")
        case .cancelled: L10n.text("Отменено")
        case .failed: L10n.text("Ошибка")
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
        case .create: L10n.text("Считать образ")
        case .restore: L10n.text("Записать образ")
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
            L10n.text("Операция отменена.")
        }
    }
}
