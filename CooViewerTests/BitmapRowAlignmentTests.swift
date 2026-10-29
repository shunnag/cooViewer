import CoreImage
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import cooViewer

final class BitmapRowAlignmentTests: XCTestCase {
    func testAlignedRowBytesPreservePixelDimensionsAndCheckOverflow() throws {
        for width in [1, 3, 15, 16, 17, 341, 1335, 1336, 1337] {
            for bpp in [1, 4] {
                let row = try XCTUnwrap(BitmapDimensions.alignedBytesPerRow(width: width, bytesPerPixel: bpp))
                XCTAssertEqual(row % 16, 0)
                XCTAssertGreaterThanOrEqual(row, width * bpp)
                XCTAssertLessThan(row - width * bpp, 16)
            }
            let size = try XCTUnwrap(BitmapDimensions(width: width, height: 7))
            XCTAssertEqual(size.width, width)
            XCTAssertEqual(size.height, 7)
            XCTAssertEqual(size.byteCount, size.bytesPerRow * 7)
        }
        for width in [0, -1, Int.max, Int.max / 4] {
            XCTAssertNil(BitmapDimensions.alignedBytesPerRow(width: width, bytesPerPixel: 4))
        }
        XCTAssertNil(BitmapDimensions.alignedBytesPerRow(width: 1, bytesPerPixel: 0))
        XCTAssertNil(BitmapDimensions(width: 1, height: Int.max))
    }

    func testCIRenderUsesAlignedRGBAAndGrayRowsWithoutChangingPixels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal が使えない環境") }
        let context = CIContext(mtlDevice: device)
        for gray in [false, true] {
            let space = CGColorSpace(name: gray ? CGColorSpace.genericGrayGamma2_2 : CGColorSpace.sRGB)!
            for width in [3, 17, 1335] {
                let size = try XCTUnwrap(BitmapDimensions(width: width, height: 3))
                let input = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
                    .cropped(to: CGRect(x: 0, y: 0, width: width, height: 3))
                let result = try XCTUnwrap(BitmapRendering.render(input, context: context, size: size, colorSpace: space))
                XCTAssertEqual(result.width, width)
                XCTAssertEqual(result.height, 3)
                XCTAssertEqual(result.bitsPerPixel, gray ? 8 : 32)
                XCTAssertEqual(result.bytesPerRow % 16, 0)
                let referenceRow = width * (gray ? 1 : 4)
                var reference = [UInt8](repeating: 0, count: referenceRow * 3)
                context.render(input, toBitmap: &reference, rowBytes: referenceRow,
                               bounds: input.extent, format: gray ? .L8 : .RGBA8, colorSpace: space)
                let actual = try XCTUnwrap(result.dataProvider?.data as Data?)
                for row in 0..<3 {
                    XCTAssertEqual(Array(actual[(row * result.bytesPerRow)..<(row * result.bytesPerRow + referenceRow)]),
                                   Array(reference[(row * referenceRow)..<((row + 1) * referenceRow)]))
                }
            }
        }
    }

    func testThumbnailAlignmentAndPNGWriterRespectStride() throws {
        let width = 17, height = 9
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let pixels = Data((0..<(width * height)).flatMap { index -> [UInt8] in
            [UInt8(index % 256), UInt8(index * 7 % 256), 64, 255]
        })
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let packed = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let aligned = ThumbnailCache.alignedForDisplay(packed)
        XCTAssertEqual(aligned.bytesPerRow % 16, 0)
        XCTAssertEqual(aligned.colorSpace, packed.colorSpace)
        XCTAssertTrue(ThumbnailCache.alignedForDisplay(aligned) === aligned)
        func encoded(_ image: CGImage, type: UTType) throws -> Data {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return data as Data
        }
        let png = try ImageDecoding.decode(encoded(aligned, type: .png))
        let reference = try ImageDecoding.decode(encoded(packed, type: .png))
        let a = try XCTUnwrap(png.dataProvider?.data as Data?)
        let b = try XCTUnwrap(reference.dataProvider?.data as Data?)
        for y in 0..<height {
            XCTAssertEqual(Array(a[(y * png.bytesPerRow)..<(y * png.bytesPerRow + width * 4)]),
                           Array(b[(y * reference.bytesPerRow)..<(y * reference.bytesPerRow + width * 4)]))
        }
    }

    func testHEICThumbnailReadKeepsAlignedRowsAndDimensions() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 341, height: 257,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 341, height: 257))
        let aligned = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, aligned, nil)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("HEIC 符号化が使えない環境") }
        let heic = try ImageDecoding.decode(data as Data)
        let thumbnail = ThumbnailCache.alignedForDisplay(heic)
        XCTAssertEqual(thumbnail.width, 341)
        XCTAssertEqual(thumbnail.height, 257)
        XCTAssertEqual(thumbnail.bytesPerRow % 16, 0)
    }
}
