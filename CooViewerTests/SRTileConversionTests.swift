import CoreML
import Foundation
import XCTest
@testable import cooViewer

/// 最適化前のスカラー実装を独立した比較基準として残す(設計書 §5、§7.6)。
enum SRScalarOracle {
    static let inputSide = 256, margin = 8, scale = 4, contentSide = 240
    static func writeTile(_ result: MLMultiArray,
                                  into out: UnsafeMutablePointer<UInt8>,
                                  bytesPerRow: Int, origin: (x: Int, y: Int),
                                  width: Int, height: Int) {
        let contentWidth = min(contentSide, width - origin.x)
        let contentHeight = min(contentSide, height - origin.y)
        // 画像端の延長幅も最適化前の式を使う(設計書 §5)。
        let extendRight = min(margin, width - origin.x - contentWidth)
        let extendBottom = min(margin, height - origin.y - contentHeight)
        let outSide = inputSide * scale
        let outMargin = margin * scale
        let planeStride = outSide * outSide
        /// 前のタイルの延長幅と同じ幅で合成する(設計書 §5)。
        let blend = margin * scale
        // 8bit 量子化では Δ1 階調の段差がフェザー後も 1 本の線として残る。
        // Bayer 8×8 の秩序ディザで丸めを空間分散させて見えなくする
        // (乱数を使わない決定的な処理なので結果は再現可能。設計書 §5)
        func component(_ value: Float, _ x: Int, _ y: Int) -> UInt8 {
            let threshold = (Float(bayer8[(y & 7) * 8 + (x & 7)]) + 0.5) / 64
            return UInt8(min(255, max(0, (value * 255 + threshold).rounded(.down))))
        }
        func write(sample: (Int) -> Float) {
            for row in 0..<((contentHeight + extendBottom) * scale) {
                let outY = origin.y * scale + row
                let outRow = outY * bytesPerRow
                let tileRow = (outMargin + row) * outSide
                // 最初のタイル行は合成相手がないため重みを 1 にする(設計書 §5)。
                let rowWeight = (origin.y > 0 && row < blend)
                    ? Float(row + 1) / Float(blend + 1) : 1
                for column in 0..<((contentWidth + extendRight) * scale) {
                    let columnWeight = (origin.x > 0 && column < blend)
                        ? Float(column + 1) / Float(blend + 1) : 1
                    let weight = rowWeight * columnWeight
                    let outX = origin.x * scale + column
                    let position = tileRow + outMargin + column
                    let pixel = outRow + outX * 4
                    if weight >= 1 {
                        out[pixel] = component(sample(position), outX, outY)
                        out[pixel + 1] = component(
                            sample(planeStride + position), outX, outY)
                        out[pixel + 2] = component(
                            sample(planeStride * 2 + position), outX, outY)
                    } else {
                        // 左・上のタイルの延長と新しい値を線形合成する(設計書 §5)。
                        let inverse = 1 - weight
                        out[pixel] = component(
                            sample(position) * weight
                            + Float(out[pixel]) / 255 * inverse, outX, outY)
                        out[pixel + 1] = component(
                            sample(planeStride + position) * weight
                            + Float(out[pixel + 1]) / 255 * inverse, outX, outY)
                        out[pixel + 2] = component(
                            sample(planeStride * 2 + position) * weight
                            + Float(out[pixel + 2]) / 255 * inverse, outX, outY)
                    }
                    out[pixel + 3] = 255
                }
            }
        }
        switch result.dataType {
        case .float32:
            let pointer = result.dataPointer.assumingMemoryBound(to: Float.self)
            write { pointer[$0] }
        case .double:
            let pointer = result.dataPointer.assumingMemoryBound(to: Double.self)
            write { Float(pointer[$0]) }
        default:
            break
        }
    }

    /// 元実装のしきい値を独立して保持する(設計書 §5、§7.6)。
    private static let bayer8: [UInt8] = [
         0, 32,  8, 40,  2, 34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44,  4, 36, 14, 46,  6, 38,
        60, 28, 52, 20, 62, 30, 54, 22,
         3, 35, 11, 43,  1, 33,  9, 41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47,  7, 39, 13, 45,  5, 37,
        63, 31, 55, 23, 61, 29, 53, 21,
    ]


}

final class SRTileConversionTests: XCTestCase {
    private let side = 1024

    private func tile(_ pattern: Int, type: MLMultiArrayDataType = .float32,
                      seed: UInt64 = 0x742AD138B6E950CF) throws -> MLMultiArray {
        let tile = try MLMultiArray(shape: [1, 3, 1024, 1024], dataType: type)
        var random = seed
        for channel in 0..<3 {
            for y in 0..<side {
                for x in 0..<side {
                    let value: Float
                    if pattern == 0 {
                        random = random &* 6364136223846793005 &+ 1442695040888963407
                        value = Float(random >> 40) / Float(1 << 24) * 1.4 - 0.2
                    } else if pattern == 1 {
                        value = Float(x + y + channel * 37) / Float(2 * side) * 1.2 - 0.1
                    } else {
                        let thresholds: [UInt8] = [
                            0,32,8,40,2,34,10,42,48,16,56,24,50,18,58,26,
                            12,44,4,36,14,46,6,38,60,28,52,20,62,30,54,22,
                            3,35,11,43,1,33,9,41,51,19,59,27,49,17,57,25,
                            15,47,7,39,13,45,5,37,63,31,55,23,61,29,53,21]
                        let threshold = (Float(thresholds[(y & 7) * 8 + (x & 7)]) + 0.5) / 64
                        let boundary = (Float((y * 13 + x * 7 + channel) % 257) - threshold) / 255
                        switch (x / 8 + y / 8) % 3 {
                        case 0: value = boundary.nextDown
                        case 1: value = boundary
                        default: value = boundary.nextUp
                        }
                    }
                    let index = channel * side * side + y * side + x
                    if type == .float32 {
                        tile.dataPointer.assumingMemoryBound(to: Float.self)[index] = value
                    } else {
                        tile.dataPointer.assumingMemoryBound(to: Double.self)[index] = Double(value)
                    }
                }
            }
        }
        return tile
    }

    private func compare(_ tile: MLMultiArray, width: Int, height: Int,
                         origins: [(x: Int, y: Int)], file: StaticString = #filePath,
                         line: UInt = #line) {
        let bytesPerRow = width * 4 * 4 + 32
        let size = bytesPerRow * height * 4
        let expected = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        let actual = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { expected.deallocate(); actual.deallocate() }
        for index in 0..<size {
            expected[index] = UInt8(truncatingIfNeeded: index &* 31)
            actual[index] = expected[index]
        }
        for origin in origins {
            SRScalarOracle.writeTile(tile, into: expected, bytesPerRow: bytesPerRow,
                                     origin: origin, width: width, height: height)
            MLSuperResolver.writeTile(tile, into: actual, bytesPerRow: bytesPerRow,
                                     origin: origin, width: width, height: height)
            if memcmp(expected, actual, size) != 0 {
                let index = (0..<size).first { expected[$0] != actual[$0] }!
                XCTFail("差分 origin=\(origin), byte=\(index), expected=\(expected[index]), actual=\(actual[index])",
                        file: file, line: line)
                return
            }
        }
    }

    func testRandomAndGradientTilesMatchScalarWithFeatherAtAllEdges() throws {
        let origins = MLSuperResolver.tileOrigins(width: 510, height: 505)
        for (pattern, seed) in [(0, UInt64(1)), (0, 0x31D2E7A9), (0, 0x742AD138B6E950CF), (1, 1)] {
            let input = try tile(pattern, seed: seed)
            // 行優先の合成と、既存画素が異なる個々の辺・角・中央を照合する(設計書 §5、§7.6)。
            compare(input, width: 510, height: 505, origins: origins)
            for origin in origins {
                compare(input, width: 510, height: 505, origins: [origin])
            }
        }
    }

    func testQuantizationBoundariesAtEveryBayerPhaseAreBitExact() throws {
        compare(try tile(2), width: 510, height: 505,
                origins: MLSuperResolver.tileOrigins(width: 510, height: 505))
    }

    func testTinyAndShortFeatherBandsAndDoubleFallbackMatchScalar() throws {
        let input = try tile(0)
        for (width, height) in [(1, 1), (7, 9), (241, 243), (249, 250)] {
            compare(input, width: width, height: height,
                    origins: MLSuperResolver.tileOrigins(width: width, height: height))
        }
        compare(try tile(1, type: .double), width: 241, height: 243,
                origins: MLSuperResolver.tileOrigins(width: 241, height: 243))
    }

    func testNonfiniteValuesAndPartialContentEdgesMatchScalar() throws {
        let values: [Float] = [
            .nan, Float(bitPattern: 0xffc01234), Float(bitPattern: 0x7f800001),
            .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
            .leastNonzeroMagnitude, -.leastNonzeroMagnitude, -0.0, 0, 1, -1, 2, 0.5,
        ]
        for type in [MLMultiArrayDataType.float32, .double] {
            let input = try MLMultiArray(shape: [1, 3, 1024, 1024], dataType: type)
            for channel in 0..<3 {
                for y in 0..<side {
                    for x in 0..<side {
                        // 各値を 8×8 の全位相に置き、短い行の末尾とフェザーも照合する(設計書 §5、§7.6)。
                        let value = values[(x / 8 + y / 8 + channel) % values.count]
                        let index = channel * side * side + y * side + x
                        if type == .float32 {
                            input.dataPointer.assumingMemoryBound(to: Float.self)[index] = value
                        } else {
                            input.dataPointer.assumingMemoryBound(to: Double.self)[index] = Double(value)
                        }
                    }
                }
            }
            for (width, height) in [(1, 1), (7, 9), (239, 237), (240, 240), (241, 243),
                                     (247, 249), (248, 248), (249, 250), (257, 263),
                                     (479, 477), (481, 483), (510, 505)] {
                compare(input, width: width, height: height,
                        origins: MLSuperResolver.tileOrigins(width: width, height: height))
            }
        }
    }

    func testTileConversionTiming() throws {
        let input = try tile(0)
        let width = 510, height = 505, bytesPerRow = width * 16
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * height * 4)
        output.initialize(repeating: 127, count: bytesPerRow * height * 4)
        defer { output.deallocate() }
        func time(_ write: () -> Void) -> Double {
            write()
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<20 { write() }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 20e6
        }
        for origin in [(x: 0, y: 0), (x: 240, y: 240)] {
            var before: [Double] = [], after: [Double] = []
            for _ in 0..<5 {
                before.append(time {
                    SRScalarOracle.writeTile(input, into: output, bytesPerRow: bytesPerRow,
                                             origin: origin, width: width, height: height)
                })
                after.append(time {
                    MLSuperResolver.writeTile(input, into: output, bytesPerRow: bytesPerRow,
                                             origin: origin, width: width, height: height)
                })
            }
            let old = before.sorted()[2], new = after.sorted()[2]
            print(String(format: "SR tile (%d,%d): scalar %.3f ms, vDSP %.3f ms, %.2fx",
                         origin.x, origin.y, old, new, old / new))
        }
    }
}
