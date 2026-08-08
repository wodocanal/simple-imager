import Foundation
import XCTest
@testable import SimpleImager

final class ImageFormatsTests: XCTestCase {
    func testEverySupportedCombinationRoundTripsThroughFileName() throws {
        for rawType in RawImageType.allCases {
            for compression in ImageCompression.allCases {
                let format = ImageFileFormat(rawType: rawType, compression: compression)
                let url = URL(fileURLWithPath: "/tmp/backup.\(format.fileSuffix)")
                XCTAssertEqual(ImageFileFormat.detect(url: url), format)
            }
        }
    }

    func testCompressedFileWithoutRawSuffixDefaultsToIMG() {
        let url = URL(fileURLWithPath: "/tmp/backup.zst")
        XCTAssertEqual(
            ImageFileFormat.detect(url: url),
            ImageFileFormat(rawType: .img, compression: .zstd)
        )
    }

    func testUnsupportedDiskAndVirtualMachineFormatsAreRejected() {
        for fileName in ["backup.iso", "backup.dmg", "backup.bin", "backup.vdi", "backup.vhd", "backup.qcow2"] {
            XCTAssertNil(ImageFileFormat.detect(url: URL(fileURLWithPath: "/tmp/\(fileName)")))
        }
    }

    func testChangingFormatReplacesExistingSupportedSuffix() {
        let source = URL(fileURLWithPath: "/tmp/card.img.zst")
        let format = ImageFileFormat(rawType: .dd, compression: .xz)
        XCTAssertEqual(format.applying(to: source).lastPathComponent, "card.dd.xz")
    }

    @MainActor
    func testOutputDirectoryNameAndFormatProduceFinalURL() {
        let model = AppModel()
        model.outputDirectoryURL = URL(fileURLWithPath: "/tmp/images", isDirectory: true)
        model.updateOutputName("daily/card:backup")
        model.selectRawImageType(.raw)
        model.selectImageCompression(.gzip)

        XCTAssertEqual(model.outputName, "daily-card-backup")
        XCTAssertEqual(model.outputURL?.path, "/tmp/images/daily-card-backup.raw.gz")
    }
}
