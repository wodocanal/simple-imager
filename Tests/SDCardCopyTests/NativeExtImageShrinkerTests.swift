import Foundation
import XCTest
@testable import SDCardCopy

final class NativeExtImageShrinkerTests: XCTestCase {
    func testFindsLastPrimaryExtPartition() throws {
        let diskSize = UInt64(16 * 1024 * 1024)
        let url = try makeImage(
            diskSize: diskSize,
            entries: [
                (type: 0x0C, firstLBA: 2048, sectors: 2048),
                (type: 0x83, firstLBA: 4096, sectors: UInt32(diskSize / 512 - 4096))
            ],
            extPartitionIndex: 1
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let plan = try NativeExtImageShrinker.analyze(handle: handle, diskSize: diskSize)

        XCTAssertEqual(plan.partitionIndex, 1)
        XCTAssertEqual(plan.firstLBA, 4096)
        XCTAssertEqual(plan.partitionOffset, 4096 * 512)
    }

    func testRejectsProtectiveGPT() throws {
        let diskSize = UInt64(8 * 1024 * 1024)
        let url = try makeImage(
            diskSize: diskSize,
            entries: [(type: 0xEE, firstLBA: 1, sectors: UInt32(diskSize / 512 - 1))],
            extPartitionIndex: nil
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        XCTAssertThrowsError(
            try NativeExtImageShrinker.analyze(handle: handle, diskSize: diskSize)
        )
    }

    func testRejectsNonExtLastPartition() throws {
        let diskSize = UInt64(8 * 1024 * 1024)
        let url = try makeImage(
            diskSize: diskSize,
            entries: [(type: 0x83, firstLBA: 2048, sectors: UInt32(diskSize / 512 - 2048))],
            extPartitionIndex: nil
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        XCTAssertThrowsError(
            try NativeExtImageShrinker.analyze(handle: handle, diskSize: diskSize)
        )
    }

    private func makeImage(
        diskSize: UInt64,
        entries: [(type: UInt8, firstLBA: UInt32, sectors: UInt32)],
        extPartitionIndex: Int?
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-ext-analyzer-\(UUID().uuidString).img")
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: diskSize)

        var mbr = Data(repeating: 0, count: 512)
        for (index, entry) in entries.enumerated() {
            let offset = 446 + index * 16
            mbr[offset + 4] = entry.type
            mbr.writeLittleUInt32(entry.firstLBA, at: offset + 8)
            mbr.writeLittleUInt32(entry.sectors, at: offset + 12)
        }
        mbr[510] = 0x55
        mbr[511] = 0xAA
        try PosixIO.writeExact(mbr, to: handle, offset: 0)

        if let extPartitionIndex {
            let partition = entries[extPartitionIndex]
            try PosixIO.writeExact(
                Data([0x53, 0xEF]),
                to: handle,
                offset: UInt64(partition.firstLBA) * 512 + 1024 + 56
            )
        }
        return url
    }
}

private extension Data {
    mutating func writeLittleUInt32(_ value: UInt32, at offset: Int) {
        for byte in 0..<4 {
            self[offset + byte] = UInt8((value >> UInt32(byte * 8)) & 0xFF)
        }
    }
}
