import Foundation

extension Data {
    func byte(at offset: Int) -> UInt8 {
        guard offset >= 0, offset < count else { return 0 }
        return self[index(startIndex, offsetBy: offset)]
    }

    func littleUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(byte(at: offset))
            | (UInt16(byte(at: offset + 1)) << 8)
    }

    func littleUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return (0..<4).reduce(UInt32(0)) { result, index in
            result | (UInt32(byte(at: offset + index)) << UInt32(index * 8))
        }
    }
}
