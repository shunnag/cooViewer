import CoreGraphics
import CoreML
import XCTest
@testable import cooViewer

final class MLNoiseBatchTests: XCTestCase {
    func testChunkingPreservesOrderAndRemainder() {
        for count in [0, 1, 31, 32, 33, 64, 65, 247] {
            let ranges = MLNoiseReducer.tileBatchRanges(tileCount: count)
            XCTAssertEqual(ranges.flatMap { Array($0) }, Array(0..<count))
            XCTAssertTrue(ranges.allSatisfy { !$0.isEmpty && $0.count <= 32 })
        }
        XCTAssertEqual(MLNoiseReducer.tileBatchRanges(tileCount: 65), [0..<32, 32..<64, 64..<65])
        XCTAssertEqual(MLNoiseReducer.tileBatchRanges(tileCount: Int.max, batchSize: Int.max), [0..<Int.max])
        XCTAssertEqual(MLNoiseReducer.tileBatchRanges(tileCount: -1), [])
        XCTAssertEqual(MLNoiseReducer.tileBatchRanges(tileCount: 1, batchSize: 0), [])
    }

    /// 画像の中心を返す疑似モデル。入力の独立性・マージン・端画素複製も通す。
    private static func echo(_ batch: MLBatchProvider) throws -> MLBatchProvider {
        var outputs: [MLFeatureProvider] = []
        var addresses: Set<UInt> = []
        for index in 0..<batch.count {
            let input = try XCTUnwrap(batch.features(at: index).featureValue(for: "input")?.multiArrayValue)
            XCTAssertTrue(addresses.insert(UInt(bitPattern: input.dataPointer)).inserted)
            let output = try MLMultiArray(shape: [1, 1, 3, 128, 128], dataType: .float32)
            let src = input.dataPointer.assumingMemoryBound(to: Float.self)
            let dst = output.dataPointer.assumingMemoryBound(to: Float.self)
            for channel in 0..<3 {
                for y in 0..<128 {
                    for x in 0..<128 {
                        dst[channel * 128 * 128 + y * 128 + x] =
                            src[channel * 142 * 142 + (y + 7) * 142 + x + 7] - 0.00196
                    }
                }
            }
            outputs.append(try MLDictionaryFeatureProvider(dictionary: ["conv7": MLFeatureValue(multiArray: output)]))
        }
        return MLArrayBatchProvider(array: outputs)
    }

    private static func image(width: Int, height: Int) throws -> CGImage {
        var data = Data(count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = (y * width + x) * 4
                data[pixel] = UInt8((x * 13 + y) % 256)
                data[pixel + 1] = UInt8((x + y * 17) % 256)
                data[pixel + 2] = UInt8((x * 3 + y * 7) % 256)
                data[pixel + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    }

    func testBatchesMatchSequentialPixelsForOddSizesAndPartialTiles() throws {
        for (width, height) in [(257, 129), (4097, 1)] {
            let image = try MLNoiseBatchTests.image(width: width, height: height)
            var counts: [Int] = []
            let batched = try XCTUnwrap(MLNoiseReducer.runTiled(image: image) {
                counts.append($0.count)
                return try MLNoiseBatchTests.echo($0)
            })
            let sequential = try XCTUnwrap(MLNoiseReducer.runTiled(image: image, batchSize: 1,
                                                                  predict: MLNoiseBatchTests.echo))
            XCTAssertEqual(batched.dataProvider?.data as Data?, sequential.dataProvider?.data as Data?)
            XCTAssertEqual(batched.bytesPerRow % 16, 0)
            XCTAssertEqual(counts, width == 4097 ? [32, 1] : [6])
            let actual = try XCTUnwrap(batched.dataProvider?.data as Data?)
            let expected = try XCTUnwrap(image.dataProvider?.data as Data?)
            for y in 0..<height {
                XCTAssertEqual(Array(actual[(y * batched.bytesPerRow)..<(y * batched.bytesPerRow + width * 4)]),
                               Array(expected[(y * image.bytesPerRow)..<((y + 1) * image.bytesPerRow)]))
            }
        }
    }

    func testCancellationAfterAChunkReturnsNoPartialImage() async throws {
        let image = try MLNoiseBatchTests.image(width: 4097, height: 1)
        let task = Task.detached {
            var calls = 0
            let result = MLNoiseReducer.runTiled(image: image) { batch in
                calls += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return try MLNoiseBatchTests.echo(batch)
            }
            return (result, calls)
        }
        let (result, calls) = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(calls, 1)
    }

    func testIncompleteOrFailedBatchReturnsNoImage() throws {
        let image = try MLNoiseBatchTests.image(width: 257, height: 129)
        XCTAssertNil(MLNoiseReducer.runTiled(image: image) { _ in MLArrayBatchProvider(array: []) })
        XCTAssertNil(MLNoiseReducer.runTiled(image: image) { _ in throw CocoaError(.coderInvalidValue) })
    }

    func testInstalledWaifu2xModelMatchesSequentialPredictionsExactly() throws {
        guard let path = ProcessInfo.processInfo.environment["COO_WAIFU2X_MODEL_PATH"] else {
            throw XCTSkip("導入済みモデルのパリティ検証は COO_WAIFU2X_MODEL_PATH 指定時に実行")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: URL(fileURLWithPath: path), configuration: configuration)
        for (width, height) in [(769, 641), (1600, 2400)] {
            let image = try MLNoiseBatchTests.image(width: width, height: height)
            let batched = try XCTUnwrap(MLNoiseReducer.runTiled(image: image) {
                try model.predictions(from: $0, options: MLPredictionOptions())
            })
            let sequential = try XCTUnwrap(MLNoiseReducer.runTiled(image: image, batchSize: 1) { batch in
                MLArrayBatchProvider(array: [try model.prediction(from: batch.features(at: 0))])
            })
            XCTAssertEqual(batched.dataProvider?.data as Data?, sequential.dataProvider?.data as Data?)
        }
    }
}
