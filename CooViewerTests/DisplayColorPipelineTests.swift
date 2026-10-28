import AppKit
import CoreImage
import ImageIO
import os
import UniformTypeIdentifiers
import XCTest
@testable import cooViewer

/// 表示先の変換・デコード分岐・灰色の確保形式をまとめて検証する(設計書 §5)。
@MainActor
final class DisplayColorPipelineTests: XCTestCase {
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

    private func image(space: CGColorSpace, width: Int = 160, height: Int = 240) throws -> CGImage {
        let gray = space.model == .monochrome
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: (gray ? CGImageAlphaInfo.none : .premultipliedLast).rawValue))
        for y in 0..<2 {
            for x in 0..<2 {
                let components: [CGFloat] = gray ? [CGFloat(1 + x + y * 2) / 5, 1]
                    : [x == 0 ? 0.8 : 0.2, y == 0 ? 0.7 : 0.1, 0.3, 1]
                context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: components)))
                context.fill(CGRect(x: x * width / 2, y: y * height / 2,
                                    width: width / 2, height: height / 2))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func encoded(_ image: CGImage, type: UTType = .jpeg, orientation: Int = 1) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func thumbnail(_ data: Data, cap: Int) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: cap,
            kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
    }

    private func rgba(_ image: CGImage, space: CGColorSpace) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try XCTUnwrap(context.makeImage())
    }

    private func assertPixels(_ actual: CGImage, _ expected: CGImage,
                              space: CGColorSpace, tolerance: Int, context: String = "",
                              file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(actual.width, expected.width, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, file: file, line: line)
        let a = try rgba(actual, space: space), b = try rgba(expected, space: space)
        let ad = try XCTUnwrap(a.dataProvider?.data as Data?)
        let bd = try XCTUnwrap(b.dataProvider?.data as Data?)
        // 設計書 §5: 境界の補間差を除き、各象限内部で色と向きを比較する。
        for y in [a.height / 4, a.height * 3 / 4] {
            for x in [a.width / 4, a.width * 3 / 4] {
                for channel in 0..<4 {
                    let delta = abs(Int(ad[y * a.bytesPerRow + x * 4 + channel])
                        - Int(bd[y * b.bytesPerRow + x * 4 + channel]))
                    XCTAssertLessThanOrEqual(delta, tolerance,
                        "\(context) 位置=\(x),\(y) 成分=\(channel)", file: file, line: line)
                }
            }
        }
    }

    /// 設計書 §5: 画面移動中も直前の完成画像を保持し、変換完了後にだけ差し替える。
    func testDisplayProfileTransitionKeepsLayerContentsUntilReplacement() async throws {
        let view = ReaderView(frame: CGRect(x: 0, y: 0, width: 160, height: 240))
        view.resampleKeyPrefix = "transition-\(UUID().uuidString)"
        let input = try image(space: srgb)
        let size = try XCTUnwrap(view.predictedResampleSizes(for: [CGSize(width: 160, height: 240)])?.first)
        let completed = try image(space: srgb, width: Int(size.width), height: Int(size.height))
        view.setPages([input], readsFromLeft: true,
            preResampled: [ResampledPage(size: size, image: completed, processing: view.imageProcessingSettings)])
        let container = try XCTUnwrap(view.layer?.sublayers?.first)
        let page = try XCTUnwrap(container.sublayers?.first)
        XCTAssertTrue(page.contents as AnyObject? === completed)
        let target = DisplayColorTarget(rgb: p3)
        XCTAssertTrue(view.invalidateDisplayColorSpace(to: target))
        XCTAssertTrue(page.contents as AnyObject? === completed)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(page.contents as AnyObject? === completed)
        for _ in 0..<200 {
            XCTAssertNotNil(page.contents)
            if let current = page.contents as! CGImage?, target.matches(current) { break }
            try? await Task.sleep(for: .milliseconds(5))
            view.layoutSubtreeIfNeeded()
        }
        let replacement = try XCTUnwrap(page.contents as! CGImage?)
        XCTAssertEqual(replacement.colorSpace, p3)
        XCTAssertFalse(replacement === completed)
    }

    /// 設計書 §5: 出力先が同じでも旧画面の入力プロファイルの計算とは合流・再利用しない。
    func testResampleCacheIncludesInputProfileWithFixedOutputTarget() async throws {
        let oldInput = try image(space: srgb)
        let newInput = try image(space: p3)
        let target = DisplayColorTarget(rgb: p3)
        let resampler = ImageResampler()
        let size = CGSize(width: 80, height: 120)
        let first = await resampler.resample(oldInput, to: size, cacheKey: "same-page",
            upscaleWithMetalFX: false, displayTarget: target)
        let stale = await resampler.cached(newInput, to: size, cacheKey: "same-page",
            upscaleWithMetalFX: false, displayTarget: target)
        XCTAssertNil(stale)
        let second = await resampler.resample(newInput, to: size, cacheKey: "same-page",
            upscaleWithMetalFX: false, displayTarget: target)
        XCTAssertFalse(first === second)
        let stats = await resampler.stats()
        XCTAssertEqual(stats.computeCount, 2)
        let expected = try XCTUnwrap(ImageResampler.cgResample(newInput, width: 80, height: 120,
            displayTarget: target))
        try assertPixels(XCTUnwrap(second), expected, space: p3, tolerance: 4)
    }

    /// 設計書 §5: 旧 SR キーを一度だけ回収し、現行の複製は期限と容量 LRU で制限する。
    func testSuperResDiskCacheMigrationAndByteEviction() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("sr-cache-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("legacy.heic")
        try Data(repeating: 1, count: 4).write(to: legacy)
        XCTAssertTrue(MLSuperResolver.prepareDiskCache(at: directory))
        XCTAssertFalse(manager.fileExists(atPath: legacy.path))
        let now = Date()
        var current: [URL] = []
        for index in 0..<3 {
            let file = directory.appendingPathComponent("current-\(index).heic")
            try Data(repeating: 2, count: 4).write(to: file)
            try manager.setAttributes([.modificationDate: now.addingTimeInterval(Double(index - 3))],
                                      ofItemAtPath: file.path)
            current.append(file)
        }
        XCTAssertTrue(MLSuperResolver.prepareDiskCache(at: directory))
        XCTAssertTrue(manager.fileExists(atPath: current[0].path))
        MLSuperResolver.trimDiskCache(at: directory, byteLimit: 8, now: now)
        XCTAssertFalse(manager.fileExists(atPath: current[0].path))
        XCTAssertTrue(manager.fileExists(atPath: current[1].path))
        XCTAssertTrue(manager.fileExists(atPath: current[2].path))
        let expired = directory.appendingPathComponent("expired.heic")
        try Data(repeating: 3, count: 4).write(to: expired)
        try manager.setAttributes([.modificationDate: now.addingTimeInterval(-31 * 86400)],
                                  ofItemAtPath: expired.path)
        let marker = directory.appendingPathComponent(".color-profile-key-v1")
        try manager.setAttributes([.modificationDate: now.addingTimeInterval(-90 * 86400)], ofItemAtPath: marker.path)
        MLSuperResolver.trimDiskCache(at: directory, olderThanDays: 30, byteLimit: 8, now: now)
        XCTAssertFalse(manager.fileExists(atPath: expired.path))
        XCTAssertTrue(manager.fileExists(atPath: marker.path))
        XCTAssertTrue(MLSuperResolver.prepareDiskCache(at: directory))
        XCTAssertTrue(manager.fileExists(atPath: current[2].path))
    }

    /// 設計書 §5: PQ・HLG はビット深度に依存せず、画像と符号値をそのまま保持する。
    func testEightBitHDRProfilesPassThroughWithoutSDRConversion() async throws {
        let data = Data((0..<(16 * 24)).flatMap { _ in [UInt8](arrayLiteral: 128, 128, 128, 255) })
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let target = DisplayColorTarget(rgb: srgb)
        for name in [CGColorSpace.itur_2100_PQ, CGColorSpace.itur_2100_HLG, CGColorSpace.displayP3_PQ] {
            let space = try XCTUnwrap(CGColorSpace(name: name))
            let input = try XCTUnwrap(CGImage(width: 16, height: 24, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: 16 * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
            XCTAssertTrue(DisplayColorTarget.preservesHDR(input))
            XCTAssertEqual(target.space(for: input), space)
            XCTAssertTrue(target.matches(input))
            XCTAssertTrue(target.converted(input) === input)
            let resampled = await ImageResampler().resample(input, to: CGSize(width: 8, height: 12),
                cacheKey: "hdr-8", upscaleWithMetalFX: false, displayTarget: target)
            XCTAssertTrue(resampled === input)
        }
    }

    /// 設計書 §5: 表示先のないサムネイルでも、近傍キャップの灰色＋透明度を失わない。
    func testNearCapGrayAlphaPNGPreservesTransparentPixelsWithoutDisplayTarget() throws {
        let width = 64, height = 1062, cap = 1000
        var pixels = Data(count: width * height * 2)
        for y in 0..<height {
            for x in (width / 2)..<width {
                pixels[(y * width + x) * 2] = 200
                pixels[(y * width + x) * 2 + 1] = 255
            }
        }
        let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let input = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 16, bytesPerRow: width * 2, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let data = try encoded(input, type: .png)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let raw = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(raw.colorSpace?.model, .monochrome)
        XCTAssertNotEqual(raw.alphaInfo, .none)
        let output = try ImageDecoding.decode(data, maxPixelSize: cap)
        XCTAssertEqual(output.bitsPerPixel, 32)
        XCTAssertNotEqual(output.alphaInfo, .none)
        let normalized = try rgba(output, space: srgb)
        let bytes = try XCTUnwrap(normalized.dataProvider?.data as Data?)
        let row = normalized.height / 2 * normalized.bytesPerRow
        XCTAssertEqual(bytes[row + normalized.width / 4 * 4 + 3], 0)
        XCTAssertEqual(bytes[row + normalized.width * 3 / 4 * 4 + 3], 255)
        XCTAssertEqual(max(output.width, output.height), cap)
        let reference = try rgba(thumbnail(data, cap: cap), space: srgb)
        let resized = try XCTUnwrap(DisplayColorTarget.draw(reference,
            width: output.width, height: output.height, space: srgb))
        try assertPixels(output, resized, space: srgb, tolerance: 1)
    }

    /// 設計書 §5: 浮動小数点の積が cap より僅かに小さくても、長辺を 1px 欠けさせない。
    func testCappedDecodeRoundsShortEdgeAndPinsLongEdgeToCap() throws {
        for (cap, long) in [(1000, 1062), (1007, 1029)] {
            for landscape in [false, true] {
                let width = landscape ? long : 64
                let height = landscape ? 64 : long
                let data = try encoded(image(space: srgb, width: width, height: height), type: .png)
                let output = try ImageDecoding.decode(data, maxPixelSize: cap)
                XCTAssertEqual(max(output.width, output.height), cap)
                XCTAssertEqual(min(output.width, output.height), Int((64.0 / Double(long) * Double(cap)).rounded()))
            }
        }
        let narrow = try XCTUnwrap(ImageDecoding.cappedDimensions(width: 1, height: 1062, cap: 1000))
        XCTAssertEqual(narrow.width, 1)
        XCTAssertEqual(narrow.height, 1000)
    }

    func testDecodePathBoundariesAndSafety() {
        XCTAssertEqual(ImageDecoding.cappedPath(width: 2133, height: 3200, cap: 3072, isJPEG: true), .full)
        XCTAssertEqual(ImageDecoding.cappedPath(width: 1100, height: 700, cap: 1000, isJPEG: false), .full)
        XCTAssertEqual(ImageDecoding.cappedPath(width: 1101, height: 700, cap: 1000, isJPEG: true), .thumbnail)
        XCTAssertEqual(ImageDecoding.cappedPath(width: 1999, height: 700, cap: 1000, isJPEG: true), .thumbnail)
        for factor in [2, 4, 8] {
            XCTAssertEqual(ImageDecoding.cappedPath(width: factor * 1000, height: 700, cap: 1000, isJPEG: true), .subsampled(factor))
        }
        XCTAssertEqual(ImageDecoding.cappedPath(width: 8000, height: 700, cap: 1000, isJPEG: false), .thumbnail)
        XCTAssertEqual(ImageDecoding.cappedPath(width: Int.max, height: Int.max, cap: Int.max, isJPEG: true), .thumbnail)
        XCTAssertEqual(ImageDecoding.cappedPath(width: 10, height: 10, cap: 0, isJPEG: true), .thumbnail)
        XCTAssertEqual(ImageDecoding.cappedPath(width: 100, height: 100, cap: 100,
            isJPEG: false, bitsPerComponent: 16), .thumbnail)
    }

    func testDecodeOutputsChooseDisplaySpaceAndRespectCap() throws {
        for space in [srgb, p3, CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!] {
            let data = try encoded(image(space: space))
            for cap in [250, 230, 170, 100, 50, 25] {
                let output = try ImageDecoding.decode(data, maxPixelSize: cap,
                    displayTarget: DisplayColorTarget(rgb: p3))
                XCTAssertEqual(output.colorSpace, space.model == .monochrome
                    ? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)! : p3)
                XCTAssertLessThanOrEqual(max(output.width, output.height), cap)
                let old = try thumbnail(data, cap: cap)
                let reference = try XCTUnwrap(DisplayColorTarget.draw(old, width: output.width,
                    height: output.height, space: p3))
                try assertPixels(output, reference, space: p3, tolerance: 5)
            }
        }
    }

    /// 設計書 §5: 変換の配置を変えても、半透明の勾配を含む全画素が一致する。
    func testDisplayRedrawMatchesOldConversionForEveryPixel() throws {
        let width = 32, height = 48
        var pixels = Data(count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let alpha = 128 + y * 127 / (height - 1)
                pixels[offset] = UInt8(x * alpha / (width - 1))
                pixels[offset + 1] = UInt8(y * alpha / (height - 1))
                pixels[offset + 2] = UInt8(alpha / 3)
                pixels[offset + 3] = UInt8(alpha)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        for sourceSpace in [srgb, p3] {
            let input = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: width * 4, space: sourceSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
            let actual = try XCTUnwrap(DisplayColorTarget(rgb: p3).converted(input))
            let normalized = try rgba(actual, space: p3)
            let reference = try rgba(input, space: p3)
            let a = try XCTUnwrap(normalized.dataProvider?.data as Data?)
            let b = try XCTUnwrap(reference.dataProvider?.data as Data?)
            for y in 0..<height {
                for byte in 0..<(width * 4) {
                    XCTAssertLessThanOrEqual(abs(Int(a[y * normalized.bytesPerRow + byte])
                        - Int(b[y * reference.bytesPerRow + byte])), 1)
                }
            }
        }
    }

    func testNearCapPNGAndUncappedDecodeChooseDisplaySpace() throws {
        for space in [srgb, p3] {
            let data = try encoded(image(space: space), type: .png)
            let target = DisplayColorTarget(rgb: p3)
            let output = try ImageDecoding.decode(data, maxPixelSize: 230, displayTarget: target)
            XCTAssertEqual(output.colorSpace, p3)
            XCTAssertLessThanOrEqual(max(output.width, output.height), 230)
            let old = try thumbnail(data, cap: 230)
            let reference = try XCTUnwrap(DisplayColorTarget.draw(old, width: output.width,
                height: output.height, space: p3))
            try assertPixels(output, reference, space: p3, tolerance: 4)
            let full = try ImageDecoding.decode(data, displayTarget: target)
            XCTAssertEqual(full.colorSpace, p3)
            XCTAssertEqual(full.width, 160)
            XCTAssertEqual(full.height, 240)
        }
    }

    func testSubsampleAndNearCapFullDecodePreserveEveryEXIFOrientation() throws {
        let input = try image(space: srgb)
        for orientation in 1...8 {
            let data = try encoded(input, orientation: orientation)
            for cap in [100, 230] {
                let output = try ImageDecoding.decode(data, maxPixelSize: cap,
                    displayTarget: DisplayColorTarget(rgb: p3))
                let reference = try thumbnail(data, cap: cap)
                XCTAssertEqual(Double(output.width), Double(reference.width), accuracy: 1)
                XCTAssertEqual(Double(output.height), Double(reference.height), accuracy: 1)
                XCTAssertLessThanOrEqual(max(output.width, output.height), cap)
                let resizedReference = try XCTUnwrap(DisplayColorTarget.draw(reference,
                    width: output.width, height: output.height, space: p3))
                try assertPixels(output, resizedReference, space: p3, tolerance: 6)
            }
        }
    }

    func testDisplayAndResampleCachesIncludeProfileAndGraySelection() async throws {
        let input = try image(space: srgb)
        let resampler = ImageResampler()
        let a = DisplayColorTarget(rgb: p3), b = DisplayColorTarget(rgb: srgb)
        XCTAssertEqual(a, DisplayColorTarget(rgb: try XCTUnwrap(CGColorSpace(iccData: p3.copyICCData()!))))
        XCTAssertNotEqual(a.identity, b.identity)
        let displayResult = await resampler.displayImage(input, cacheKey: "display", target: a)
        let display = try XCTUnwrap(displayResult)
        let same = await resampler.displayImage(input, cacheKey: "display", target: a)
        XCTAssertTrue(display === same)
        let original = await resampler.displayImage(input, cacheKey: "display", target: b)
        XCTAssertTrue(original === input)
        for target in [a, b] {
            let size = CGSize(width: 80, height: 120)
            let resampled = await resampler.resample(input, to: size, cacheKey: "page",
                upscaleWithMetalFX: false, displayTarget: target)
            let result = try XCTUnwrap(resampled)
            XCTAssertEqual(result.colorSpace, target.rgb)
            let cached = await resampler.cached(input, to: size, cacheKey: "page",
                upscaleWithMetalFX: false, displayTarget: target)
            XCTAssertTrue(result === cached)
            let expected = try XCTUnwrap(ImageResampler.cgResample(input, width: 80, height: 120))
            try assertPixels(result, expected, space: p3, tolerance: 4)
        }
        let stats = await resampler.stats()
        XCTAssertEqual(stats.computeCount, 2)
    }

    func testDecodedPageCacheSeparatesDisplayProfiles() throws {
        let cache = PageCache(byteLimit: 1 << 20)
        let input = try image(space: srgb)
        let target = DisplayColorTarget(rgb: p3)
        let converted = try XCTUnwrap(target.converted(input))
        cache.insert(input, for: 7, colorSpaceIdentity: DisplayColorTarget(rgb: srgb).identity)
        XCTAssertNil(cache.image(for: 7, colorSpaceIdentity: target.identity))
        cache.insert(converted, for: 7, colorSpaceIdentity: target.identity)
        XCTAssertTrue(cache.image(for: 7, colorSpaceIdentity: target.identity) === converted)
        XCTAssertTrue(cache.image(for: 7, colorSpaceIdentity: DisplayColorTarget(rgb: srgb).identity) === input)
        XCTAssertEqual(cache.count, 2)
    }

    func testVerifiedGrayStaysSingleChannelOnCPU() async throws {
        let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        let input = try image(space: space)
        let target = DisplayColorTarget(rgb: p3)
        XCTAssertEqual(target.gray, space)
        XCTAssertNotEqual(target.identity, DisplayColorTarget(rgb: p3, verifiedGray: nil).identity)
        let data = try encoded(input)
        for cap in [230, 100] {
            let decoded = try ImageDecoding.decode(data, maxPixelSize: cap, displayTarget: target)
            XCTAssertEqual(decoded.colorSpace?.model, .monochrome)
            XCTAssertEqual(decoded.bitsPerPixel, 8)
        }
        let cpu = try XCTUnwrap(ImageResampler.cgResample(input, width: 80, height: 120, displayTarget: target))
        XCTAssertEqual(cpu.colorSpace, space)
        XCTAssertEqual(cpu.bitsPerPixel, 8)
        let resampler = ImageResampler()
        let resampled = await resampler.resample(input, to: CGSize(width: 80, height: 120),
            cacheKey: "gray", upscaleWithMetalFX: false, displayTarget: target)
        let result = try XCTUnwrap(resampled)
        XCTAssertEqual(result.colorSpace, space)
        XCTAssertEqual(result.bitsPerPixel, 8)
        let rgbResult = await resampler.resample(input, to: CGSize(width: 80, height: 120),
            cacheKey: "gray", upscaleWithMetalFX: false,
            displayTarget: DisplayColorTarget(rgb: p3, verifiedGray: nil))
        let rgb = try XCTUnwrap(rgbResult)
        XCTAssertEqual(rgb.colorSpace, p3)
        XCTAssertEqual(rgb.bitsPerPixel, 32)
    }

    /// 設計書 §5: 全体復号・サムネイル・縮小復号の後も、灰色と RGB の出力先を混ぜない。
    func testGrayAndRGBJPEGDecodeThenResampleUseDefaultOutputSpaces() async throws {
        let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        XCTAssertEqual(DisplayColorTarget.current(window: nil).gray, gray)
        let target = DisplayColorTarget(rgb: p3)
        let resampler = ImageResampler()
        for sourceSpace in [gray, srgb] {
            let isGray = sourceSpace == gray
            for orientation in [1, 6] {
                let data = try encoded(image(space: sourceSpace), orientation: orientation)
                for cap in [250, 230, 170, 100, 50, 25] {
                    let decoded = try ImageDecoding.decode(data, maxPixelSize: cap, displayTarget: target)
                    let expectedSpace = isGray ? gray : p3
                    XCTAssertEqual(decoded.colorSpace, expectedSpace)
                    XCTAssertEqual(decoded.bitsPerComponent, 8)
                    XCTAssertEqual(decoded.bitsPerPixel, isGray ? 8 : 32)
                    XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), cap)
                    let size = CGSize(width: max(1, decoded.width / 2), height: max(1, decoded.height / 2))
                    let output = await resampler.resample(decoded, to: size,
                        cacheKey: "jpeg-\(isGray)-\(orientation)-\(cap)",
                        upscaleWithMetalFX: false, displayTarget: target)
                    let result = try XCTUnwrap(output)
                    XCTAssertEqual(result.colorSpace, expectedSpace)
                    XCTAssertEqual(result.bitsPerComponent, 8)
                    XCTAssertEqual(result.bitsPerPixel, isGray ? 8 : 32)
                    if isGray {
                        XCTAssertEqual(result.colorSpace?.numberOfComponents, 1)
                        XCTAssertEqual(result.alphaInfo, .none)
                        XCTAssertTrue(target.matches(result))
                        XCTAssertTrue(target.converted(result) === result)
                    }
                    XCTAssertLessThanOrEqual(max(result.width, result.height), cap)
                    // 設計書 §5: cap=25 の 8×12px では四分点も境界の影響を受け、
                    // ImageIO/CG と Lanczos の核の違いを測ってしまう。形式・色空間・寸法は全 cap、
                    // 色変換の画素比較は境界から離れた点を取れる cap≥50 で検証する。
                    if cap >= 50 {
                        let reference = try XCTUnwrap(DisplayColorTarget.draw(thumbnail(data, cap: cap),
                            width: result.width, height: result.height, space: expectedSpace))
                        try assertPixels(result, reference, space: p3, tolerance: 5,
                            context: "灰色=\(isGray) 向き=\(orientation) cap=\(cap)")
                    }
                }
            }
        }
    }

    /// 設計書 §5: 透明度つき灰色と高ビット深度は除外し、低ビット灰色は Gray8 へ正規化する。
    func testDefaultGraySelectionRequiresOpaqueSingleChannel() throws {
        let target = DisplayColorTarget(rgb: p3)
        let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let transparent = try XCTUnwrap(context.makeImage())
        XCTAssertFalse(DisplayColorTarget.isOpaqueGray(transparent))
        XCTAssertEqual(target.space(for: transparent), p3)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(repeating: 0x55, count: 32) as CFData))
        let packed = try XCTUnwrap(CGImage(width: 16, height: 16, bitsPerComponent: 1,
            bitsPerPixel: 1, bytesPerRow: 2, space: space, bitmapInfo: [],
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        XCTAssertTrue(DisplayColorTarget.isOpaqueGray(packed))
        let normalized = try XCTUnwrap(target.converted(packed))
        XCTAssertEqual(normalized.colorSpace, space)
        XCTAssertEqual(normalized.bitsPerComponent, 8)
        XCTAssertEqual(normalized.bitsPerPixel, 8)
    }

    /// 設計書 §5: 中間の RGB 化を最終キャッシュに持ち越さず、灰色の低メモリ形式を保つ。
    func testGrayOutputSurvivesRGBProcessingIntermediates() async throws {
        let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        let input = try image(space: space)
        let rgb = try XCTUnwrap(DisplayColorTarget.draw(input,
            width: input.width, height: input.height, space: p3))
        let enlarged = try XCTUnwrap(DisplayColorTarget.draw(input,
            width: input.width * 2, height: input.height * 2, space: p3))
        let resampler = ImageResampler(noiseReductionOverride: { _, _ in rgb },
                                       upscaleOverride: { _, _ in enlarged })
        let target = DisplayColorTarget(rgb: p3)
        for (size, reduction, upscale) in [
            (CGSize(width: 80, height: 120), NoiseReductionLevel.medium, false),
            (CGSize(width: 160, height: 240), .medium, false),
            (CGSize(width: 320, height: 480), .none, true),
        ] {
            let output = await resampler.resample(input, to: size,
                cacheKey: "gray-intermediate-\(size.width)", upscaleWithMetalFX: upscale,
                noiseReduction: reduction, displayTarget: target)
            let result = try XCTUnwrap(output)
            XCTAssertEqual(result.colorSpace, space)
            XCTAssertEqual(result.bitsPerComponent, 8)
            XCTAssertEqual(result.bitsPerPixel, 8)
        }
    }

    func testGPUOutputsUseTargetSpaceAndMatchConvertedOldPixels() throws {
        guard let scaler = LanczosDownscaler() else { throw XCTSkip("Metal が使えない環境") }
        let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        for sourceSpace in [srgb, p3, gray] {
            let input = try image(space: sourceSpace)
            let target = DisplayColorTarget(rgb: p3)
            let gpu = try XCTUnwrap(scaler.downscale(input, to: CGSize(width: 80, height: 120), displayTarget: target))
            let old = try XCTUnwrap(scaler.downscale(input, to: CGSize(width: 80, height: 120)))
            XCTAssertEqual(gpu.colorSpace, target.space(for: input))
            if sourceSpace == gray {
                XCTAssertEqual(gpu.bitsPerPixel, 8)
                XCTAssertEqual(gpu.bytesPerRow, 80)
            }
            try assertPixels(gpu, old, space: p3, tolerance: 4)
        }
    }

    func testHDRKeepsExtendedRangeAndOriginalStorage() async throws {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        var pixels = [Float16](repeating: 0, count: 32 * 48 * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = 2
            pixels[offset + 1] = 1
            pixels[offset + 2] = 0.5
            pixels[offset + 3] = 1
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let input = try XCTUnwrap(CGImage(width: 32, height: 48, bitsPerComponent: 16,
            bitsPerPixel: 64, bytesPerRow: 32 * 8, space: space,
            bitmapInfo: [.floatComponents, .byteOrder16Little,
                         CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let target = DisplayColorTarget(rgb: srgb)
        XCTAssertTrue(target.converted(input) === input)
        XCTAssertEqual(target.space(for: input), space)
        let result = await ImageResampler().resample(input, to: CGSize(width: 16, height: 24),
            cacheKey: "hdr", upscaleWithMetalFX: false, displayTarget: target)
        XCTAssertTrue(result === input)
        XCTAssertEqual(result?.bitsPerComponent, 16)
    }

    /// 設計書 §5: I/O 中に辞退した先読みも、枠が空いたという理由でデコードを再開しない。
    func testDeclinedPrefetchDoesNotStartWhenGateIsFree() async throws {
        let promotion = DecodePromotion()
        promotion.declineQueuedPrefetch()
        let gate = SourceReadGate(limit: 2)
        let decoded = OSAllocatedUnfairLock(initialState: false)
        do {
            _ = try await PrefetchDecodeGate.run(isPrefetch: true, gate: gate, promotion: promotion) {
                decoded.withLock { $0 = true }
                return 1
            }
            XCTFail("辞退した先読みを実行した")
        } catch is PrefetchDecodeGate.Declined { }
        XCTAssertFalse(decoded.withLock { $0 })
        let counts = await gate.debugCounts()
        XCTAssertEqual(counts.active, 0)
        XCTAssertEqual(counts.queued, 0)
    }

    func testPrefetchDecodeLimitAndDisplayBypass() async throws {
        let gate = SourceReadGate(limit: PrefetchDecodeGate.concurrencyLimit)
        let first = await gate.acquire(interactive: false)
        let second = await gate.acquire(interactive: false)
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        let background = Task.detached {
            try await PrefetchDecodeGate.run(isPrefetch: true, gate: gate) { 1 }
        }
        while await gate.debugCounts().queued == 0 { await Task.yield() }
        let display = try await PrefetchDecodeGate.run(isPrefetch: false, gate: gate) { 2 }
        XCTAssertEqual(display, 2)
        background.cancel()
        await gate.release()
        await gate.release()
        _ = try? await background.value
        let counts = await gate.debugCounts()
        XCTAssertEqual(counts.active, 0)
        XCTAssertEqual(counts.queued, 0)
        let state = OSAllocatedUnfairLock(initialState: (active: 0, peak: 0))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await PrefetchDecodeGate.run(isPrefetch: true, gate: gate) {
                        state.withLock { $0.active += 1; $0.peak = max($0.peak, $0.active) }
                        Thread.sleep(forTimeInterval: 0.01)
                        state.withLock { $0.active -= 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(state.withLock { $0.peak }, 2)
    }
}
