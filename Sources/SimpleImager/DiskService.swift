import Foundation
import IOKit

enum DiskService {
    private static let diskutil = "/usr/sbin/diskutil"

    static func listExternalPhysicalDisks() throws -> [DiskInfo] {
        let data = try CommandRunner.requireSuccess(diskutil, ["list", "-plist", "external", "physical"])
        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let root = propertyList as? [String: Any],
              let identifiers = root["WholeDisks"] as? [String] else {
            throw AppError.invalidResponse("diskutil вернул неизвестный формат списка дисков.")
        }

        return try identifiers
            .map(info(for:))
            .filter { !$0.isInternal && $0.isWhole && $0.isPhysical }
            .sorted { $0.mediaName.localizedStandardCompare($1.mediaName) == .orderedAscending }
    }

    static func info(for identifier: String) throws -> DiskInfo {
        guard isWholeDiskIdentifier(identifier) else {
            throw AppError.unsafeDisk("Недопустимый идентификатор диска: \(identifier)")
        }

        let data = try CommandRunner.requireSuccess(diskutil, ["info", "-plist", "/dev/\(identifier)"])
        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let values = propertyList as? [String: Any] else {
            throw AppError.invalidResponse("Не удалось прочитать свойства \(identifier).")
        }

        let actualIdentifier = values["DeviceIdentifier"] as? String ?? identifier
        let sizeNumber = values["TotalSize"] as? NSNumber
        let virtualOrPhysical = (values["VirtualOrPhysical"] as? String)?.lowercased()
        let physical = virtualOrPhysical != "virtual" && (values["SystemImage"] as? Bool ?? false) == false
        let identity = try registryIdentity(for: actualIdentifier)

        return DiskInfo(
            identifier: actualIdentifier,
            mediaName: values["MediaName"] as? String ?? values["IORegistryEntryName"] as? String ?? actualIdentifier,
            size: sizeNumber?.uint64Value ?? 0,
            registryEntryID: identity.entryID,
            registryPath: identity.path,
            serialNumber: identity.serialNumber,
            isInternal: values["Internal"] as? Bool ?? true,
            isRemovable: values["RemovableMedia"] as? Bool ?? false,
            isWhole: values["WholeDisk"] as? Bool ?? values["Whole"] as? Bool ?? false,
            isPhysical: physical
        )
    }

    static func requireSafeExternalWholeDisk(_ identifier: String) throws -> DiskInfo {
        let disk = try info(for: identifier)
        guard disk.identifier == identifier,
              !disk.isInternal,
              disk.isWhole,
              disk.isPhysical,
              disk.size > 0 else {
            throw AppError.unsafeDisk("Операция разрешена только для целого внешнего физического диска.")
        }
        return disk
    }

    static func unmount(_ disk: DiskInfo) throws {
        _ = try CommandRunner.requireSuccess(diskutil, ["unmountDisk", disk.devicePath])
    }

    static func mount(_ disk: DiskInfo) {
        _ = try? CommandRunner.requireSuccess(diskutil, ["mountDisk", disk.devicePath])
    }

    @discardableResult
    static func eject(_ disk: DiskInfo) -> Bool {
        (try? CommandRunner.requireSuccess(diskutil, ["eject", disk.devicePath])) != nil
    }

    static func isWholeDiskIdentifier(_ value: String) -> Bool {
        value.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil
    }

    private static func registryIdentity(for identifier: String) throws -> RegistryIdentity {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, identifier),
              case let service = IOServiceGetMatchingService(kIOMainPortDefault, matching),
              service != IO_OBJECT_NULL else {
            throw AppError.invalidResponse("Не удалось найти \(identifier) в IORegistry.")
        }
        defer { IOObjectRelease(service) }

        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else {
            throw AppError.invalidResponse("Не удалось получить идентификатор IORegistry для \(identifier).")
        }

        var pathBuffer = [CChar](repeating: 0, count: 4096)
        guard IORegistryEntryGetPath(service, kIOServicePlane, &pathBuffer) == KERN_SUCCESS else {
            throw AppError.invalidResponse("Не удалось получить путь IORegistry для \(identifier).")
        }

        return RegistryIdentity(
            entryID: entryID,
            path: String(cString: pathBuffer),
            serialNumber: serialNumber(startingAt: service)
        )
    }

    private static func serialNumber(startingAt service: io_registry_entry_t) -> String? {
        let keys = ["Serial Number", "USB Serial Number", "kUSBSerialNumberString", "SerialNumber"]
        var current = service
        var shouldReleaseCurrent = false
        defer {
            if shouldReleaseCurrent { IOObjectRelease(current) }
        }

        while current != IO_OBJECT_NULL {
            for key in keys {
                guard let value = IORegistryEntryCreateCFProperty(
                    current,
                    key as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue() else { continue }
                if let serial = value as? String {
                    let normalized = serial.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !normalized.isEmpty { return normalized }
                }
                if let number = value as? NSNumber { return number.stringValue }
            }

            var parent: io_registry_entry_t = IO_OBJECT_NULL
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                break
            }
            if shouldReleaseCurrent { IOObjectRelease(current) }
            current = parent
            shouldReleaseCurrent = true
        }
        return nil
    }

    private struct RegistryIdentity {
        let entryID: UInt64
        let path: String
        let serialNumber: String?
    }
}
