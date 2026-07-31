import Foundation

@main
enum CompactAnalyzerSmoke {
    static func main() throws {
        try testFAT32()
        try testExFAT()
        print("Compact analyzer smoke tests passed (FAT32, exFAT).")
    }

    private static func testFAT32() throws {
        let clusterCount = 65_525
        let fatSectors = 512
        let totalSectors = 1 + fatSectors * 2 + clusterCount
        var disk = Data(repeating: 0, count: totalSectors * 512)
        disk.put16(512, at: 11)
        disk[13] = 1
        disk.put16(1, at: 14)
        disk[16] = 2
        disk.put32(UInt32(totalSectors), at: 32)
        disk.put32(UInt32(fatSectors), at: 36)
        disk[510] = 0x55
        disk[511] = 0xAA

        let fatStart = 512
        disk.put32(0x0FFF_FFF8, at: fatStart)
        disk.put32(0xFFFF_FFFF, at: fatStart + 4)
        disk.put32(0x0FFF_FFFF, at: fatStart + 8)
        let mirrorStart = fatStart + fatSectors * 512
        disk.replaceSubrange(mirrorStart..<(mirrorStart + fatSectors * 512), with: disk[fatStart..<(fatStart + fatSectors * 512)])

        let plan = try analyze(disk)
        guard let region = plan.regions.first, region.fileSystem == "FAT32" else {
            throw SmokeError.failed("FAT32 was not recognized")
        }
        var clusters = Data(repeating: 0x7A, count: Int(region.clusterSize * 2))
        plan.sanitize(&clusters, at: region.dataOffset)
        guard clusters.prefix(Int(region.clusterSize)).allSatisfy({ $0 == 0x7A }),
              clusters.suffix(Int(region.clusterSize)).allSatisfy({ $0 == 0 }) else {
            throw SmokeError.failed("FAT32 allocation map sanitized the wrong clusters")
        }
    }

    private static func testExFAT() throws {
        let sectorSize = 512
        let volumeSectors = 2_048
        let fatOffset = 24
        let heapOffset = 25
        let clusterCount = 64
        var disk = Data(repeating: 0, count: volumeSectors * sectorSize)
        disk.replaceSubrange(3..<11, with: Data("EXFAT   ".utf8))
        disk.put64(UInt64(volumeSectors), at: 72)
        disk.put32(UInt32(fatOffset), at: 80)
        disk.put32(1, at: 84)
        disk.put32(UInt32(heapOffset), at: 88)
        disk.put32(UInt32(clusterCount), at: 92)
        disk.put32(2, at: 96)
        disk[108] = 9
        disk[110] = 1

        let fatStart = fatOffset * sectorSize
        disk.put32(0xFFFF_FFFF, at: fatStart + 2 * 4)
        disk.put32(0xFFFF_FFFF, at: fatStart + 3 * 4)
        let rootOffset = heapOffset * sectorSize
        disk[rootOffset] = 0x81
        disk.put32(3, at: rootOffset + 20)
        disk.put64(8, at: rootOffset + 24)
        disk[rootOffset + sectorSize] = 0b0000_0111

        let plan = try analyze(disk)
        guard let region = plan.regions.first, region.fileSystem == "exFAT" else {
            throw SmokeError.failed("exFAT was not recognized")
        }
        var clusters = Data(repeating: 0x41, count: Int(region.clusterSize * 4))
        plan.sanitize(&clusters, at: region.dataOffset)
        guard clusters.prefix(Int(region.clusterSize * 3)).allSatisfy({ $0 == 0x41 }),
              clusters.suffix(Int(region.clusterSize)).allSatisfy({ $0 == 0 }) else {
            throw SmokeError.failed("exFAT allocation bitmap sanitized the wrong clusters")
        }
    }

    private static func analyze(_ data: Data) throws -> CompactPlan {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sd-smoke-\(UUID().uuidString).img")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return CompactImageAnalyzer.buildPlan(handle: handle, diskSize: UInt64(data.count))
    }
}

private enum SmokeError: Error {
    case failed(String)
}

private extension Data {
    mutating func put16(_ value: UInt16, at offset: Int) {
        for index in 0..<2 { self[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    mutating func put32(_ value: UInt32, at offset: Int) {
        for index in 0..<4 { self[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    mutating func put64(_ value: UInt64, at offset: Int) {
        for index in 0..<8 { self[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
}
