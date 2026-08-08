import Foundation

struct PartitionRegion: Equatable {
    let offset: UInt64
    let length: UInt64
    let name: String
}

struct AllocationRegion {
    let fileSystem: String
    let partitionName: String
    let dataOffset: UInt64
    let clusterSize: UInt64
    let clusterCount: UInt64
    let allocatedBits: Data

    func isAllocated(cluster: UInt64) -> Bool {
        guard cluster < clusterCount else { return true }
        let byteIndex = Int(cluster / 8)
        let mask = UInt8(1 << (cluster % 8))
        return byteIndex < allocatedBits.count && (allocatedBits.byte(at: byteIndex) & mask) != 0
    }
}

struct CompactPlan {
    let regions: [AllocationRegion]
    let rawPartitions: [String]

    var compactedFileSystems: [String] {
        regions.map { "\($0.partitionName): \($0.fileSystem)" }
    }

    func sanitize(_ data: inout Data, at absoluteOffset: UInt64) {
        let chunkEnd = absoluteOffset + UInt64(data.count)

        for region in regions {
            let regionEnd = region.dataOffset + region.clusterSize * region.clusterCount
            let intersectionStart = max(absoluteOffset, region.dataOffset)
            let intersectionEnd = min(chunkEnd, regionEnd)
            guard intersectionStart < intersectionEnd else { continue }

            let firstCluster = (intersectionStart - region.dataOffset) / region.clusterSize
            let lastCluster = (intersectionEnd - 1 - region.dataOffset) / region.clusterSize

            for cluster in firstCluster...lastCluster where !region.isAllocated(cluster: cluster) {
                let clusterStart = region.dataOffset + cluster * region.clusterSize
                let clusterEnd = clusterStart + region.clusterSize
                let zeroStart = max(intersectionStart, clusterStart)
                let zeroEnd = min(intersectionEnd, clusterEnd)
                let localStart = Int(zeroStart - absoluteOffset)
                let localEnd = Int(zeroEnd - absoluteOffset)
                data.resetBytes(in: localStart..<localEnd)
            }
        }
    }
}

final class RandomAccessReader {
    private let handle: FileHandle
    let size: UInt64

    init(handle: FileHandle, size: UInt64) {
        self.handle = handle
        self.size = size
    }

    func read(offset: UInt64, count: Int) throws -> Data {
        guard count >= 0,
              offset <= size,
              UInt64(count) <= size - offset else {
            throw AppError.archiveInvalid("Структура раздела выходит за границы диска.")
        }
        return try PosixIO.readExact(from: handle, offset: offset, count: count)
    }
}

enum CompactImageAnalyzer {
    static func buildPlan(handle: FileHandle, diskSize: UInt64) -> CompactPlan {
        let reader = RandomAccessReader(handle: handle, size: diskSize)
        let partitions = (try? discoverPartitions(reader: reader)) ?? [
            PartitionRegion(offset: 0, length: diskSize, name: "Весь носитель")
        ]

        var regions: [AllocationRegion] = []
        var rawPartitions: [String] = []

        for partition in partitions {
            if let region = try? parseExFAT(partition: partition, reader: reader) {
                regions.append(region)
            } else if let region = try? parseFAT32(partition: partition, reader: reader) {
                regions.append(region)
            } else {
                rawPartitions.append(partition.name)
            }
        }

        return CompactPlan(regions: regions, rawPartitions: rawPartitions)
    }

    static func discoverPartitions(reader: RandomAccessReader) throws -> [PartitionRegion] {
        guard reader.size >= 512 else { return [] }
        let sector = try reader.read(offset: 0, count: 512)
        guard sector.byte(at: 510) == 0x55, sector.byte(at: 511) == 0xAA else {
            return [PartitionRegion(offset: 0, length: reader.size, name: "Весь носитель")]
        }

        var mbrEntries: [(type: UInt8, firstLBA: UInt64, sectors: UInt64)] = []
        for index in 0..<4 {
            let offset = 446 + index * 16
            let type = sector.byte(at: offset + 4)
            let firstLBA = UInt64(sector.littleUInt32(at: offset + 8) ?? 0)
            let sectors = UInt64(sector.littleUInt32(at: offset + 12) ?? 0)
            if type != 0, sectors > 0 {
                mbrEntries.append((type, firstLBA, sectors))
            }
        }

        if mbrEntries.contains(where: { $0.type == 0xEE }) {
            for sectorSize in [UInt64(512), UInt64(4096)] where reader.size >= sectorSize * 2 {
                if let partitions = try? discoverGPT(reader: reader, sectorSize: sectorSize), !partitions.isEmpty {
                    return partitions
                }
            }
        }

        let partitions = mbrEntries.enumerated().compactMap { index, entry -> PartitionRegion? in
            let start = entry.firstLBA * 512
            let length = entry.sectors * 512
            guard start < reader.size, length <= reader.size - start else { return nil }
            return PartitionRegion(offset: start, length: length, name: "Раздел MBR \(index + 1)")
        }
        return partitions.isEmpty
            ? [PartitionRegion(offset: 0, length: reader.size, name: "Весь носитель")]
            : partitions
    }

    private static func discoverGPT(reader: RandomAccessReader, sectorSize: UInt64) throws -> [PartitionRegion] {
        let header = try reader.read(offset: sectorSize, count: Int(sectorSize))
        guard header.ascii(at: 0, count: 8) == "EFI PART",
              let entriesLBA = header.littleUInt64(at: 72),
              let entryCountValue = header.littleUInt32(at: 80),
              let entrySizeValue = header.littleUInt32(at: 84) else {
            return []
        }

        let entryCount = Int(entryCountValue)
        let entrySize = Int(entrySizeValue)
        guard (128...4096).contains(entrySize), (1...4096).contains(entryCount) else { return [] }
        let tableSize = entryCount * entrySize
        let tableOffset = entriesLBA * sectorSize
        guard tableSize <= 16 * 1024 * 1024 else { return [] }
        let table = try reader.read(offset: tableOffset, count: tableSize)

        var partitions: [PartitionRegion] = []
        for index in 0..<entryCount {
            let offset = index * entrySize
            let typeGUID = table.subdata(in: offset..<(offset + 16))
            guard typeGUID.contains(where: { $0 != 0 }),
                  let firstLBA = table.littleUInt64(at: offset + 32),
                  let lastLBA = table.littleUInt64(at: offset + 40),
                  lastLBA >= firstLBA else { continue }

            let start = firstLBA * sectorSize
            let length = (lastLBA - firstLBA + 1) * sectorSize
            guard start < reader.size, length <= reader.size - start else { continue }

            let nameEnd = min(offset + entrySize, offset + 128)
            let rawName = table.subdata(in: (offset + 56)..<nameEnd)
            let decodedName = String(data: rawName, encoding: .utf16LittleEndian)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = decodedName?.isEmpty == false ? decodedName! : "Раздел GPT \(index + 1)"
            partitions.append(PartitionRegion(offset: start, length: length, name: name))
        }
        return partitions
    }

    private static func parseFAT32(partition: PartitionRegion, reader: RandomAccessReader) throws -> AllocationRegion {
        let boot = try reader.read(offset: partition.offset, count: 512)
        guard boot.byte(at: 510) == 0x55,
              boot.byte(at: 511) == 0xAA,
              let bytesPerSectorValue = boot.littleUInt16(at: 11),
              let reservedValue = boot.littleUInt16(at: 14),
              let totalSectorsValue = boot.littleUInt32(at: 32),
              let fatSectorsValue = boot.littleUInt32(at: 36) else {
            throw AppError.archiveInvalid("Не FAT32")
        }

        let bytesPerSector = UInt64(bytesPerSectorValue)
        let sectorsPerCluster = UInt64(boot.byte(at: 13))
        let reservedSectors = UInt64(reservedValue)
        let numberOfFATs = UInt64(boot.byte(at: 16))
        let rootEntries = boot.littleUInt16(at: 17) ?? 1
        let fat16Size = boot.littleUInt16(at: 22) ?? 1
        let totalSectors = UInt64(totalSectorsValue)
        let fatSectors = UInt64(fatSectorsValue)

        guard [512, 1024, 2048, 4096].contains(bytesPerSector),
              sectorsPerCluster > 0,
              sectorsPerCluster <= 128,
              sectorsPerCluster.nonzeroBitCount == 1,
              reservedSectors > 0,
              (1...4).contains(numberOfFATs),
              rootEntries == 0,
              fat16Size == 0,
              fatSectors > 0,
              totalSectors > reservedSectors + numberOfFATs * fatSectors,
              totalSectors * bytesPerSector <= partition.length else {
            throw AppError.archiveInvalid("Некорректная FAT32")
        }

        let dataSectors = totalSectors - reservedSectors - numberOfFATs * fatSectors
        let clusterCount = dataSectors / sectorsPerCluster
        let clusterSize = sectorsPerCluster * bytesPerSector
        let fatBytes = fatSectors * bytesPerSector
        guard clusterCount >= 65_525,
              clusterCount <= 100_000_000,
              (clusterCount + 2) * 4 <= fatBytes,
              fatBytes <= 512 * 1024 * 1024 else {
            throw AppError.archiveInvalid("Неподдерживаемый размер FAT32")
        }

        let flags = boot.littleUInt16(at: 40) ?? 0
        let mirroringDisabled = (flags & 0x0080) != 0
        let activeFAT = mirroringDisabled ? UInt64(flags & 0x000F) : 0
        guard activeFAT < numberOfFATs else { throw AppError.archiveInvalid("Некорректная активная FAT") }

        let firstFATOffset = partition.offset + reservedSectors * bytesPerSector
        let selectedFATOffset = firstFATOffset + activeFAT * fatBytes
        let fat = try reader.read(offset: selectedFATOffset, count: Int((clusterCount + 2) * 4))

        if !mirroringDisabled, numberOfFATs > 1 {
            let mirror = try reader.read(offset: firstFATOffset + fatBytes, count: fat.count)
            guard mirror == fat else { throw AppError.archiveInvalid("Копии FAT различаются") }
        }

        var bits = Data(repeating: 0, count: Int((clusterCount + 7) / 8))
        for cluster in UInt64(0)..<clusterCount {
            let entry = (fat.littleUInt32(at: Int((cluster + 2) * 4)) ?? 1) & 0x0FFF_FFFF
            if entry != 0 {
                bits.setBit(Int(cluster))
            }
        }

        let dataOffset = partition.offset + (reservedSectors + numberOfFATs * fatSectors) * bytesPerSector
        return AllocationRegion(
            fileSystem: "FAT32",
            partitionName: partition.name,
            dataOffset: dataOffset,
            clusterSize: clusterSize,
            clusterCount: clusterCount,
            allocatedBits: bits
        )
    }

    private static func parseExFAT(partition: PartitionRegion, reader: RandomAccessReader) throws -> AllocationRegion {
        let boot = try reader.read(offset: partition.offset, count: 512)
        guard boot.ascii(at: 3, count: 8) == "EXFAT   ",
              let volumeSectors = boot.littleUInt64(at: 72),
              let fatOffsetValue = boot.littleUInt32(at: 80),
              let fatLengthValue = boot.littleUInt32(at: 84),
              let heapOffsetValue = boot.littleUInt32(at: 88),
              let clusterCountValue = boot.littleUInt32(at: 92),
              let rootClusterValue = boot.littleUInt32(at: 96),
              let volumeFlags = boot.littleUInt16(at: 106) else {
            throw AppError.archiveInvalid("Не exFAT")
        }

        let bytesPerSectorShift = Int(boot.byte(at: 108))
        let sectorsPerClusterShift = Int(boot.byte(at: 109))
        let numberOfFATs = Int(boot.byte(at: 110))
        guard (9...12).contains(bytesPerSectorShift),
              (0...16).contains(sectorsPerClusterShift),
              (1...2).contains(numberOfFATs) else {
            throw AppError.archiveInvalid("Некорректная геометрия exFAT")
        }

        let bytesPerSector = UInt64(1 << bytesPerSectorShift)
        let sectorsPerCluster = UInt64(1 << sectorsPerClusterShift)
        let clusterSize = bytesPerSector * sectorsPerCluster
        let fatOffset = UInt64(fatOffsetValue) * bytesPerSector
        let fatLength = UInt64(fatLengthValue) * bytesPerSector
        let heapOffset = UInt64(heapOffsetValue) * bytesPerSector
        let clusterCount = UInt64(clusterCountValue)
        let rootCluster = UInt64(rootClusterValue)
        let volumeLength = volumeSectors * bytesPerSector

        guard clusterSize > 0,
              clusterSize <= 32 * 1024 * 1024,
              clusterCount > 0,
              clusterCount <= 500_000_000,
              rootCluster >= 2,
              rootCluster < clusterCount + 2,
              volumeLength <= partition.length,
              heapOffset + clusterCount * clusterSize <= volumeLength,
              (clusterCount + 2) * 4 <= fatLength else {
            throw AppError.archiveInvalid("Некорректные границы exFAT")
        }

        let activeFAT = numberOfFATs == 2 ? Int(volumeFlags & 0x0001) : 0
        let selectedFATOffset = partition.offset + fatOffset + UInt64(activeFAT) * fatLength
        let fat = try reader.read(offset: selectedFATOffset, count: Int((clusterCount + 2) * 4))

        func clusterData(_ cluster: UInt64) throws -> Data {
            guard cluster >= 2, cluster < clusterCount + 2 else {
                throw AppError.archiveInvalid("Кластер exFAT вне диапазона")
            }
            let offset = partition.offset + heapOffset + (cluster - 2) * clusterSize
            return try reader.read(offset: offset, count: Int(clusterSize))
        }

        func nextCluster(_ cluster: UInt64) throws -> UInt64? {
            guard let value = fat.littleUInt32(at: Int(cluster * 4)) else {
                throw AppError.archiveInvalid("Поврежденная FAT exFAT")
            }
            let next = UInt64(value)
            if next >= 0xFFFF_FFF8 { return nil }
            guard next >= 2, next < clusterCount + 2 else {
                throw AppError.archiveInvalid("Некорректная цепочка exFAT")
            }
            return next
        }

        var current: UInt64? = rootCluster
        var visited = Set<UInt64>()
        var bitmapEntry: (firstCluster: UInt64, length: UInt64)?

        while let cluster = current, visited.insert(cluster).inserted, visited.count <= Int(clusterCount) {
            let directory = try clusterData(cluster)
            for entryOffset in stride(from: 0, to: directory.count, by: 32) {
                let entryType = directory.byte(at: entryOffset)
                if entryType == 0x00 { current = nil; break }
                if entryType == 0x81 {
                    let bitmapID = Int(directory.byte(at: entryOffset + 1) & 0x01)
                    if numberOfFATs == 1 || bitmapID == activeFAT,
                       let first = directory.littleUInt32(at: entryOffset + 20),
                       let length = directory.littleUInt64(at: entryOffset + 24) {
                        bitmapEntry = (UInt64(first), length)
                        current = nil
                        break
                    }
                }
            }
            if current != nil { current = try nextCluster(cluster) }
        }

        guard let bitmapEntry,
              bitmapEntry.firstCluster >= 2,
              bitmapEntry.length >= (clusterCount + 7) / 8,
              bitmapEntry.length <= clusterCount else {
            throw AppError.archiveInvalid("Не найдена карта распределения exFAT")
        }

        var bitmap = Data()
        bitmap.reserveCapacity(Int(bitmapEntry.length))
        current = bitmapEntry.firstCluster
        visited.removeAll(keepingCapacity: true)
        while let cluster = current, bitmap.count < Int(bitmapEntry.length), visited.insert(cluster).inserted {
            let remaining = Int(bitmapEntry.length) - bitmap.count
            bitmap.append(try clusterData(cluster).prefix(remaining))
            current = try nextCluster(cluster)
        }
        guard bitmap.count == Int(bitmapEntry.length) else {
            throw AppError.archiveInvalid("Карта распределения exFAT прочитана не полностью")
        }

        return AllocationRegion(
            fileSystem: "exFAT",
            partitionName: partition.name,
            dataOffset: partition.offset + heapOffset,
            clusterSize: clusterSize,
            clusterCount: clusterCount,
            allocatedBits: bitmap
        )
    }
}

extension Data {
    func byte(at offset: Int) -> UInt8 {
        guard offset >= 0, offset < count else { return 0 }
        return self[index(startIndex, offsetBy: offset)]
    }

    func littleUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(byte(at: offset)) | (UInt16(byte(at: offset + 1)) << 8)
    }

    func littleUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return (0..<4).reduce(UInt32(0)) { result, index in
            result | (UInt32(byte(at: offset + index)) << UInt32(index * 8))
        }
    }

    func littleUInt64(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        return (0..<8).reduce(UInt64(0)) { result, index in
            result | (UInt64(byte(at: offset + index)) << UInt64(index * 8))
        }
    }

    func ascii(at offset: Int, count length: Int) -> String? {
        guard offset >= 0, length >= 0, offset + length <= count else { return nil }
        return String(data: subdata(in: offset..<(offset + length)), encoding: .ascii)
    }

    mutating func setBit(_ bit: Int) {
        guard bit >= 0 else { return }
        let byteIndex = bit / 8
        guard byteIndex < count else { return }
        let dataIndex = index(startIndex, offsetBy: byteIndex)
        self[dataIndex] |= UInt8(1 << (bit % 8))
    }
}
