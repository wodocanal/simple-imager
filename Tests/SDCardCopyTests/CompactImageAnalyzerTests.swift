import Foundation
import XCTest
@testable import SDCardCopy

final class CompactImageAnalyzerTests: XCTestCase {
    func testFAT32PlanZerosOnlyFreeClusters() throws {
        let disk = makeFAT32Disk()
        let plan = try analyze(disk)

        XCTAssertEqual(plan.regions.count, 1)
        XCTAssertEqual(plan.regions.first?.fileSystem, "FAT32")
        XCTAssertTrue(plan.rawPartitions.isEmpty)

        let region = try XCTUnwrap(plan.regions.first)
        var clusters = Data(repeating: 0x7A, count: Int(region.clusterSize * 2))
        plan.sanitize(&clusters, at: region.dataOffset)

        XCTAssertTrue(clusters.prefix(Int(region.clusterSize)).allSatisfy { $0 == 0x7A })
        XCTAssertTrue(clusters.suffix(Int(region.clusterSize)).allSatisfy { $0 == 0 })
    }

    func testMismatchedFATCopiesFallBackToRaw() throws {
        var disk = makeFAT32Disk()
        let fatBytes = 512 * 512
        disk[512 + fatBytes + 8] = 0x01

        let plan = try analyze(disk)

        XCTAssertTrue(plan.regions.isEmpty)
        XCTAssertEqual(plan.rawPartitions, ["Весь носитель"])
    }

    func testExFATPlanUsesAllocationBitmap() throws {
        let disk = makeExFATDisk()
        let plan = try analyze(disk)

        XCTAssertEqual(plan.regions.count, 1)
        XCTAssertEqual(plan.regions.first?.fileSystem, "exFAT")

        let region = try XCTUnwrap(plan.regions.first)
        var clusters = Data(repeating: 0x41, count: Int(region.clusterSize * 4))
        plan.sanitize(&clusters, at: region.dataOffset)

        XCTAssertTrue(clusters.prefix(Int(region.clusterSize * 3)).allSatisfy { $0 == 0x41 })
        XCTAssertTrue(clusters.suffix(Int(region.clusterSize)).allSatisfy { $0 == 0 })
    }

    private func analyze(_ disk: Data) throws -> CompactPlan {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sd-card-copy-test-\(UUID().uuidString).img")
        try disk.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return CompactImageAnalyzer.buildPlan(handle: handle, diskSize: UInt64(disk.count))
    }

    private func makeFAT32Disk() -> Data {
        let clusterCount = 65_525
        let fatSectors = 512
        let totalSectors = 1 + fatSectors * 2 + clusterCount
        var disk = Data(repeating: 0, count: totalSectors * 512)

        disk.writeUInt16(512, at: 11)
        disk[13] = 1
        disk.writeUInt16(1, at: 14)
        disk[16] = 2
        disk.writeUInt16(0, at: 17)
        disk.writeUInt16(0, at: 22)
        disk.writeUInt32(UInt32(totalSectors), at: 32)
        disk.writeUInt32(UInt32(fatSectors), at: 36)
        disk[510] = 0x55
        disk[511] = 0xAA

        let fatStart = 512
        disk.writeUInt32(0x0FFF_FFF8, at: fatStart)
        disk.writeUInt32(0xFFFF_FFFF, at: fatStart + 4)
        disk.writeUInt32(0x0FFF_FFFF, at: fatStart + 8)
        let mirrorStart = fatStart + fatSectors * 512
        disk.replaceSubrange(mirrorStart..<(mirrorStart + fatSectors * 512), with: disk[fatStart..<(fatStart + fatSectors * 512)])
        return disk
    }

    private func makeExFATDisk() -> Data {
        let sectorSize = 512
        let volumeSectors = 2_048
        let fatOffset = 24
        let fatLength = 1
        let heapOffset = 25
        let clusterCount = 64
        var disk = Data(repeating: 0, count: volumeSectors * sectorSize)

        disk.replaceSubrange(3..<11, with: Data("EXFAT   ".utf8))
        disk.writeUInt64(UInt64(volumeSectors), at: 72)
        disk.writeUInt32(UInt32(fatOffset), at: 80)
        disk.writeUInt32(UInt32(fatLength), at: 84)
        disk.writeUInt32(UInt32(heapOffset), at: 88)
        disk.writeUInt32(UInt32(clusterCount), at: 92)
        disk.writeUInt32(2, at: 96)
        disk.writeUInt16(0, at: 106)
        disk[108] = 9
        disk[109] = 0
        disk[110] = 1

        let fatStart = fatOffset * sectorSize
        disk.writeUInt32(0xFFFF_FFFF, at: fatStart + 2 * 4)
        disk.writeUInt32(0xFFFF_FFFF, at: fatStart + 3 * 4)

        let rootOffset = heapOffset * sectorSize
        disk[rootOffset] = 0x81
        disk[rootOffset + 1] = 0
        disk.writeUInt32(3, at: rootOffset + 20)
        disk.writeUInt64(8, at: rootOffset + 24)
        disk[rootOffset + 32] = 0

        let bitmapOffset = rootOffset + sectorSize
        disk[bitmapOffset] = 0b0000_0111
        return disk
    }

    static var allTests = [
        ("testFAT32PlanZerosOnlyFreeClusters", testFAT32PlanZerosOnlyFreeClusters),
        ("testMismatchedFATCopiesFallBackToRaw", testMismatchedFATCopiesFallBackToRaw),
        ("testExFATPlanUsesAllocationBitmap", testExFATPlanUsesAllocationBitmap)
    ]
}

private extension Data {
    mutating func writeUInt16(_ value: UInt16, at offset: Int) {
        for index in 0..<2 { self[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        for index in 0..<4 { self[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    mutating func writeUInt64(_ value: UInt64, at offset: Int) {
        for index in 0..<8 { self[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
}

#if MANUAL_TEST_RUNNER
@main
enum ManualTestRunner {
    static func main() {
        XCTMain([
            testCase(CompactImageAnalyzerTests.allTests)
        ])
    }
}
#endif
