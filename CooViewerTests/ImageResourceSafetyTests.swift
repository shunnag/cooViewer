import CoreGraphics
import os
import XCTest
@testable import cooViewer

final class ImageResourceSafetyTests: XCTestCase {
    func testMetalFXNormalizesCMYKAndGrayWithoutLosingColor() throws {
        guard let upscaler = MetalFXUpscaler() else { throw XCTSkip("MetalFX が使えない環境") }
        for (space, sample) in [(CGColorSpaceCreateDeviceCMYK(), [UInt8](arrayLiteral: 32, 128, 0, 32)),
                                (CGColorSpaceCreateDeviceGray(), [UInt8](arrayLiteral: 128))] {
            let data = Data((0..<(64 * 64)).flatMap { _ in sample })
            let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
            let input = try XCTUnwrap(CGImage(width: 64, height: 64, bitsPerComponent: 8,
                bitsPerPixel: sample.count * 8, bytesPerRow: 64 * sample.count, space: space,
                bitmapInfo: [], provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
            let expected = try XCTUnwrap(ImageResampler.cgResample(input, width: 128, height: 128))
            let result = try XCTUnwrap(upscaler.upscale(input, to: CGSize(width: 128, height: 128)))
            XCTAssertEqual(result.colorSpace?.model, .rgb)
            let actualBytes = try XCTUnwrap(result.dataProvider?.data as Data?)
            let expectedBytes = try XCTUnwrap(expected.dataProvider?.data as Data?)
            for channel in 0..<3 {
                let actual = Int(actualBytes[64 * result.bytesPerRow + 64 * 4 + channel])
                let reference = Int(expectedBytes[64 * expected.bytesPerRow + 64 * 4 + channel])
                XCTAssertLessThanOrEqual(abs(actual - reference), 10)
            }
        }
    }
    func testTextureDimensionLimitRejectsOversizedEdgesAndCachesCPUFallback() async throws {
        guard let upscaler = MetalFXUpscaler() else { throw XCTSkip("MetalFX が使えない環境") }
        func image(width: Int) throws -> CGImage {
            let provider = try XCTUnwrap(CGDataProvider(data: Data(count: width * 2 * 4) as CFData))
            return try XCTUnwrap(CGImage(width: width, height: 2, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        }
        let limit = upscaler.maximumTextureDimension
        let small = try image(width: 16)
        let wide = try image(width: limit + 1)
        XCTAssertNil(upscaler.upscale(small, to: CGSize(width: limit + 1, height: 4)))
        XCTAssertNil(upscaler.upscale(small, to: CGSize(width: 32, height: limit + 1)))
        XCTAssertNil(upscaler.upscale(wide, to: CGSize(width: limit + 2, height: 4)))
        let resampler = ImageResampler(pressure: FixedMemoryPressure())
        let size = CGSize(width: limit + 1, height: 4)
        let first = await resampler.resample(small, to: size, cacheKey: "wide", upscaleWithMetalFX: true)
        XCTAssertEqual(first?.width, limit + 1)
        let second = await resampler.resample(small, to: size, cacheKey: "wide", upscaleWithMetalFX: true)
        XCTAssertTrue(first === second)
        let stats = await resampler.stats()
        XCTAssertEqual(stats.computeCount, 1)
    }
    func testTemporaryUpscaleFailureDoesNotFreezeCPUFallback() async throws {
        let image = try ImageDecoding.decode(TestFixtures.pngData(width: 20, height: 20))
        let enhanced = try ImageDecoding.decode(TestFixtures.pngData(width: 40, height: 40, red: 0.8))
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let resampler = ImageResampler(pressure: FixedMemoryPressure(), upscaleOverride: { _, _ in
            calls.withLock { count in
                count += 1
                return count == 1 ? nil : enhanced
            }
        })
        let target = CGSize(width: 40, height: 40)
        let fallback = await resampler.resample(image, to: target, cacheKey: "gpu-recover", upscaleWithMetalFX: true)
        XCTAssertEqual(fallback?.width, 40)
        let absent = await resampler.cached(image, to: target, cacheKey: "gpu-recover", upscaleWithMetalFX: true)
        XCTAssertNil(absent)
        let recovered = await resampler.resample(image, to: target, cacheKey: "gpu-recover", upscaleWithMetalFX: true)
        XCTAssertTrue(recovered === enhanced)
        let cached = await resampler.resample(image, to: target, cacheKey: "gpu-recover", upscaleWithMetalFX: true)
        XCTAssertTrue(cached === enhanced)
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }
    func testDirectGPURendersPreserveOrientationColorAndAlpha() throws {
        guard let scaler = LanczosDownscaler(), let reducer = NoiseReducer() else {
            throw XCTSkip("Metal が使えない環境")
        }
        var bytes = Data(count: 80 * 60 * 4)
        for y in 0..<60 {
            for x in 0..<80 {
                let offset = (y * 80 + x) * 4
                bytes[offset] = x < 40 ? 230 : 20
                bytes[offset + 1] = x < 40 ? 20 : 230
                bytes[offset + 2] = y < 30 ? 20 : 230
                bytes[offset + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let input = try XCTUnwrap(CGImage(width: 80, height: 60, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 80 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let outputs = [try XCTUnwrap(scaler.downscale(input, to: CGSize(width: 40, height: 30))),
                       try XCTUnwrap(reducer.reduce(input, level: .medium))]
        for output in outputs {
            let data = try XCTUnwrap(output.dataProvider?.data as Data?)
            for (x, y, red, green, blue) in [(1, 1, true, false, false), (3, 1, false, true, false),
                                           (1, 3, true, false, true), (3, 3, false, true, true)] {
                let offset = (output.height * y / 4) * output.bytesPerRow + output.width * x / 4 * 4
                for (channel, high) in [red, green, blue].enumerated() {
                    if high { XCTAssertGreaterThan(Int(data[offset + channel]), 180) }
                    else { XCTAssertLessThan(Int(data[offset + channel]), 80) }
                }
                XCTAssertEqual(data[offset + 3], 255)
            }
        }
    }
    func testMetalFXUpscalingPreservesOrientationAndQuadrantColors() throws {
        guard let upscaler = MetalFXUpscaler() else { throw XCTSkip("MetalFX が使えない環境") }
        for alphaInfo: CGImageAlphaInfo in [.premultipliedLast, .premultipliedFirst] {
            var bytes = Data(count: 80 * 60 * 4)
            let alphaFirst = alphaInfo == .premultipliedFirst
            for y in 0..<60 {
                for x in 0..<80 {
                    let offset = (y * 80 + x) * 4
                    let colorOffset = offset + (alphaFirst ? 1 : 0)
                    bytes[colorOffset] = x < 40 ? 230 : 20
                    bytes[colorOffset + 1] = x < 40 ? 20 : 230
                    bytes[colorOffset + 2] = y < 30 ? 20 : 230
                    bytes[offset + (alphaFirst ? 0 : 3)] = 255
                }
            }
            let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
            let input = try XCTUnwrap(CGImage(width: 80, height: 60, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: 80 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
            for target in [CGSize(width: 150, height: 110), CGSize(width: 400, height: 300)] {
                let output = try XCTUnwrap(upscaler.upscale(input, to: target))
                let data = try XCTUnwrap(output.dataProvider?.data as Data?)
                for (x, y, red, green, blue) in [(1, 1, true, false, false), (3, 1, false, true, false),
                                               (1, 3, true, false, true), (3, 3, false, true, true)] {
                    let offset = (output.height * y / 4) * output.bytesPerRow + output.width * x / 4 * 4
                    for (channel, high) in [red, green, blue].enumerated() {
                        if high { XCTAssertGreaterThan(Int(data[offset + channel]), 180) }
                        else { XCTAssertLessThan(Int(data[offset + channel]), 80) }
                    }
                    XCTAssertEqual(data[offset + 3], 255)
                }
            }
        }
    }
    func testInvalidDimensionsAreRejectedBeforeConversionOrAllocation() {
        for value: CGFloat in [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -1, 0] {
            XCTAssertNil(BitmapDimensions(CGSize(width: value, height: 64)))
            XCTAssertNil(BitmapDimensions(CGSize(width: 64, height: value)))
        }
        XCTAssertNil(BitmapDimensions(width: Int.max, height: 2))
        XCTAssertNil(BitmapDimensions(width: 100_000, height: 100_000))
        let nearest = BitmapDimensions(CGSize(width: 10.6, height: 20.4), rounding: .toNearestOrAwayFromZero)
        XCTAssertEqual(nearest?.width, 11)
        XCTAssertEqual(nearest?.height, 20)
        XCTAssertEqual(BitmapDimensions(CGSize(width: 10.6, height: 20.4))?.width, 10)
    }

    func testResamplerRejectsInvalidTargetWithoutComputingOrCaching() async throws {
        let image = try ImageDecoding.decode(TestFixtures.pngData(width: 20, height: 20))
        let resampler = ImageResampler(pressure: FixedMemoryPressure())
        for value: CGFloat in [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -1, 0] {
            let target = CGSize(width: value, height: 20)
            let result = await resampler.resample(image, to: target, cacheKey: "invalid", upscaleWithMetalFX: true)
            let cached = await resampler.cached(image, to: target, cacheKey: "invalid", upscaleWithMetalFX: true)
            XCTAssertNil(result)
            XCTAssertNil(cached)
        }
        let stats = await resampler.stats()
        XCTAssertEqual(stats.computeCount, 0)
        XCTAssertEqual(stats.count, 0)
    }

    func testTemporaryNoiseFailureIsNotCachedAndRecoveryIsUsed() async throws {
        let image = try ImageDecoding.decode(TestFixtures.pngData(width: 20, height: 20))
        let filtered = try ImageDecoding.decode(TestFixtures.pngData(width: 20, height: 20, red: 0.8))
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let resampler = ImageResampler(pressure: FixedMemoryPressure(), noiseReductionOverride: { _, _ in
            calls.withLock { count in
                count += 1
                return count == 1 ? nil : filtered
            }
        })
        let target = CGSize(width: 20, height: 20)
        let first = await resampler.resample(image, to: target, cacheKey: "recover",
            upscaleWithMetalFX: false, noiseReduction: .medium)
        XCTAssertTrue(first === image)
        let absent = await resampler.cached(image, to: target, cacheKey: "recover",
            upscaleWithMetalFX: false, noiseReduction: .medium)
        XCTAssertNil(absent)
        let second = await resampler.resample(image, to: target, cacheKey: "recover",
            upscaleWithMetalFX: false, noiseReduction: .medium)
        XCTAssertTrue(second === filtered)
        let third = await resampler.resample(image, to: target, cacheKey: "recover",
            upscaleWithMetalFX: false, noiseReduction: .medium)
        XCTAssertTrue(third === filtered)
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }
}
