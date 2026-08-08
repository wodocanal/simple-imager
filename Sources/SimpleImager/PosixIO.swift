import Darwin
import Foundation

struct SparseRange {
    let offset: UInt64
    let length: UInt64
}

struct SparseWriteResult {
    let ranges: [SparseRange]

    var skippedBytes: UInt64 {
        ranges.reduce(0) { $0 + $1.length }
    }
}

enum PosixIO {
    private static let sparsePageSize = 64 * 1024

    static func configureSequentialDevice(_ handle: FileHandle) {
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        _ = fcntl(handle.fileDescriptor, F_RDAHEAD, 1)
    }

    static func readBlock(from handle: FileHandle, count: Int) throws -> Data {
        guard count >= 0 else {
            throw AppError.invalidArguments("Некорректный размер блока чтения.")
        }

        var data = Data(count: count)
        let bytesRead = try data.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            var total = 0

            while total < count {
                let result = Darwin.read(
                    handle.fileDescriptor,
                    baseAddress.advanced(by: total),
                    count - total
                )
                if result > 0 {
                    total += result
                } else if result == 0 {
                    break
                } else if errno != EINTR {
                    throw posixError(operation: "чтения")
                }
            }
            return total
        }

        if bytesRead < data.count {
            data.removeSubrange(bytesRead..<data.count)
        }
        return data
    }

    static func readExact(from handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= UInt64(Int64.max) else {
            throw AppError.archiveInvalid("Структура раздела выходит за границы диска.")
        }

        var data = Data(count: count)
        let bytesRead = try data.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            var total = 0

            while total < count {
                let result = Darwin.pread(
                    handle.fileDescriptor,
                    baseAddress.advanced(by: total),
                    count - total,
                    off_t(offset) + off_t(total)
                )
                if result > 0 {
                    total += result
                } else if result == 0 {
                    break
                } else if errno != EINTR {
                    throw posixError(operation: "чтения структуры файловой системы")
                }
            }
            return total
        }

        guard bytesRead == count else {
            throw AppError.archiveInvalid("Не удалось полностью прочитать структуру файловой системы.")
        }
        return data
    }

    static func writeAll(_ data: Data, to handle: FileHandle) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            try writeBuffer(baseAddress, count: buffer.count, to: handle.fileDescriptor)
        }
    }

    static func writeExact(_ data: Data, to handle: FileHandle, offset: UInt64) throws {
        guard offset <= UInt64(Int64.max) else {
            throw AppError.invalidArguments("Некорректная позиция записи.")
        }
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var total = 0
            while total < buffer.count {
                let result = Darwin.pwrite(
                    handle.fileDescriptor,
                    baseAddress.advanced(by: total),
                    buffer.count - total,
                    off_t(offset) + off_t(total)
                )
                if result > 0 {
                    total += result
                } else if result == 0 {
                    throw AppError.commandFailed("Запись структуры образа неожиданно остановилась.")
                } else if errno != EINTR {
                    throw posixError(operation: "записи структуры образа")
                }
            }
        }
    }

    @discardableResult
    static func writeSparse(_ data: Data, to handle: FileHandle) throws -> SparseWriteResult {
        try data.withUnsafeBytes { rawBuffer -> SparseWriteResult in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard let baseAddress = rawBuffer.baseAddress else {
                return SparseWriteResult(ranges: [])
            }
            let descriptor = handle.fileDescriptor
            let absoluteStart = Darwin.lseek(descriptor, 0, SEEK_CUR)
            guard absoluteStart >= 0 else {
                throw posixError(operation: "позиционирования разреженного образа")
            }

            try writeBuffer(baseAddress, count: rawBuffer.count, to: descriptor)

            func pageIsZero(start: Int, end: Int) -> Bool {
                for index in start..<end where bytes[index] != 0 { return false }
                return true
            }

            var offset = 0
            var ranges: [SparseRange] = []
            while offset < bytes.count {
                let firstEnd = min(offset + sparsePageSize, bytes.count)
                let zeroRun = pageIsZero(start: offset, end: firstEnd)
                var runEnd = firstEnd

                while runEnd < bytes.count {
                    let pageEnd = min(runEnd + sparsePageSize, bytes.count)
                    guard pageIsZero(start: runEnd, end: pageEnd) == zeroRun else { break }
                    runEnd = pageEnd
                }

                let runLength = runEnd - offset
                if zeroRun {
                    var hole = fpunchhole_t(
                        fp_flags: 0,
                        reserved: 0,
                        fp_offset: absoluteStart + off_t(offset),
                        fp_length: off_t(runLength)
                    )
                    if Darwin.fcntl(descriptor, F_PUNCHHOLE, &hole) == 0 {
                        ranges.append(
                            SparseRange(
                                offset: UInt64(absoluteStart) + UInt64(offset),
                                length: UInt64(runLength)
                            )
                        )
                    } else if errno == ENOTSUP || errno == EINVAL || errno == ENOTTY {
                        return SparseWriteResult(ranges: ranges)
                    } else {
                        throw posixError(operation: "освобождения нулевых блоков образа")
                    }
                }
                offset = runEnd
            }
            return SparseWriteResult(ranges: ranges)
        }
    }

    static func finalizeSparseFile(_ handle: FileHandle, ranges: [SparseRange]) throws {
        let logicalSize = Darwin.lseek(handle.fileDescriptor, 0, SEEK_CUR)
        guard logicalSize >= 0, Darwin.ftruncate(handle.fileDescriptor, logicalSize) == 0 else {
            throw posixError(operation: "завершения разреженного образа")
        }

        // APFS can reallocate earlier holes while later blocks are appended, so punch once more at EOF.
        for range in merged(ranges) {
            var hole = fpunchhole_t(
                fp_flags: 0,
                reserved: 0,
                fp_offset: off_t(range.offset),
                fp_length: off_t(range.length)
            )
            if Darwin.fcntl(handle.fileDescriptor, F_PUNCHHOLE, &hole) != 0,
               errno != ENOTSUP,
               errno != EINVAL,
               errno != ENOTTY {
                throw posixError(operation: "финального освобождения нулевых блоков")
            }
        }
    }

    static func replaceWithZeroOrSparseRanges(
        _ handle: FileHandle,
        ranges: [SparseRange]
    ) throws {
        let zeroChunk = Data(repeating: 0, count: 1024 * 1024)
        for range in merged(ranges) {
            var hole = fpunchhole_t(
                fp_flags: 0,
                reserved: 0,
                fp_offset: off_t(range.offset),
                fp_length: off_t(range.length)
            )
            if Darwin.fcntl(handle.fileDescriptor, F_PUNCHHOLE, &hole) == 0 {
                continue
            }
            guard errno == ENOTSUP || errno == EINVAL || errno == ENOTTY else {
                throw posixError(operation: "освобождения пустых ext-блоков образа")
            }

            var offset = range.offset
            var remaining = range.length
            while remaining > 0 {
                let count = Int(min(UInt64(zeroChunk.count), remaining))
                let data = count == zeroChunk.count ? zeroChunk : Data(zeroChunk.prefix(count))
                try writeExact(data, to: handle, offset: offset)
                offset += UInt64(count)
                remaining -= UInt64(count)
            }
        }
        try handle.synchronize()
    }

    private static func merged(_ ranges: [SparseRange]) -> [SparseRange] {
        var result: [SparseRange] = []
        for range in ranges
            .filter({ $0.length > 0 && $0.offset <= UInt64.max - $0.length })
            .sorted(by: { $0.offset < $1.offset }) {
            if let previous = result.last,
               previous.offset + previous.length >= range.offset {
                let end = max(previous.offset + previous.length, range.offset + range.length)
                result[result.count - 1] = SparseRange(
                    offset: previous.offset,
                    length: end - previous.offset
                )
            } else {
                result.append(range)
            }
        }
        return result
    }

    private static func writeBuffer(
        _ baseAddress: UnsafeRawPointer,
        count: Int,
        to descriptor: Int32
    ) throws {
        var total = 0
        while total < count {
            let result = Darwin.write(
                descriptor,
                baseAddress.advanced(by: total),
                count - total
            )
            if result > 0 {
                total += result
            } else if result == 0 {
                throw AppError.commandFailed("Запись на накопитель неожиданно остановилась.")
            } else if errno != EINTR {
                throw posixError(operation: "записи")
            }
        }
    }

    private static func posixError(operation: String) -> AppError {
        let code = errno
        return AppError.commandFailed(
            "Ошибка \(operation) накопителя: \(String(cString: strerror(code))) (errno \(code))."
        )
    }
}
