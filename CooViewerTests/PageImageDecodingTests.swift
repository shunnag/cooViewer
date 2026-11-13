import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import cooViewer
@testable import PrintAppearanceKit

/// ページのデコードの入口の検査(設計書 §5): 網点処理の要求がなければ ImageDecoding.decode と同じ画素、
/// 素通しのページは要求があっても同じ画素(上限の内でも外でも)、処理するページは原寸で処理してから縮めた
/// 1 チャンネルの Generic Gray 2.2。画像はすべてテストの中で合成する。
/// 処理の期待値は CPU の厳密な経路のエンジンで prepare + process を直接呼んで作る(GPU に依存しない)
final class PageImageDecodingTests: XCTestCase {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    private static let targets: [DisplayColorTarget?] = [
        nil, DisplayColorTarget(rgb: sRGB), DisplayColorTarget(rgb: p3),
    ]

    // MARK: - 要求なし

    /// 要求がなければ従来のデコードと同じ画素(サービスには触れない)
    func testWithoutRequestEqualsImageDecoding() async throws {
        let gray = try Self.grayPNG(PrintAppearanceTestPages.screen(width: 300, height: 420, period: 4, angle: 45),
                                    width: 300, height: 420)
        let colour = try Self.colourJPEG(width: 600, height: 800)
        for data in [gray, colour] {
            for cap in [nil, 1000, 600, 300] as [Int?] {
                for target in Self.targets {
                    let image = try await PageRequestIntent.$displayColorTarget.withValue(target) {
                        try await PageImageDecoding.decode(data, maxPixelSize: cap)
                    }
                    let expected = try ImageDecoding.decode(data, maxPixelSize: cap, displayTarget: target)
                    Self.assertIdentical(image, expected, "cap \(String(describing: cap)) target \(Self.name(target))")
                }
            }
        }
    }

    // MARK: - 素通し

    /// 色のあるページは、要求があっても網点処理を切ったときと同じ画素(上限の内・1.1 倍以内・2 倍未満・2 倍以上、
    /// 上限なし。表示先なし・sRGB・P3)
    func testColourPageWithRequestEqualsImageDecoding() async throws {
        let service = Self.service()
        let jpeg = try Self.colourJPEG(width: 600, height: 800)
        let png = try Self.colourPNG(width: 600, height: 800)
        for (name, data) in [("jpeg", jpeg), ("png", png)] {
            guard case .passThrough(.colour, _) = try PrintAppearance.prepare(data, maxPixels: service.maxPixels) else {
                return XCTFail("\(name): 色のあるページと判定されない")
            }
            for cap in [nil, 1000, 760, 600, 400] as [Int?] {
                for target in Self.targets {
                    let image = try await Self.decode(data, cap: cap, target: target, service: service)
                    let expected = try ImageDecoding.decode(data, maxPixelSize: cap, displayTarget: target)
                    Self.assertIdentical(image, expected,
                                         "\(name) cap \(String(describing: cap)) target \(Self.name(target))")
                }
            }
        }
        XCTAssertEqual(service.stats().passedThrough[.colour], 2 * 5 * 3)
        XCTAssertEqual(service.stats().processedPages, 0)
    }

    /// 小さすぎるページ・透明な画素のあるページも同じ画素で素通しにする
    func testOtherPassThroughEqualsImageDecoding() async throws {
        let service = Self.service()
        let small = try Self.grayPNG(PrintAppearanceTestPages.flat(width: 100, height: 140, value: 90),
                                     width: 100, height: 140)
        let transparent = try Self.transparentPNG(width: 300, height: 420)
        for (data, reason) in [(small, PrintAppearancePassReason.small), (transparent, .transparency)] {
            for cap in [nil, 120, 300] as [Int?] {
                for target in Self.targets {
                    let image = try await Self.decode(data, cap: cap, target: target, service: service)
                    let expected = try ImageDecoding.decode(data, maxPixelSize: cap, displayTarget: target)
                    Self.assertIdentical(image, expected, "\(reason) cap \(String(describing: cap))")
                }
            }
            XCTAssertEqual(service.stats().passedThrough[reason], 3 * Self.targets.count)
        }
    }

    // MARK: - 処理

    /// グレーのページは prepare + process と同じ 1 チャンネルの Generic Gray 2.2(表示先があっても変えない)
    func testGrayPageIsProcessedToGenericGray() async throws {
        let service = Self.service()
        let luma = PrintAppearanceTestPages.screen(width: 384, height: 512, period: 4, angle: 45)
        let data = try Self.grayPNG(luma, width: 384, height: 512)
        let expected = try Self.expected(data, level: .standard, cap: nil)
        XCTAssertNotEqual(Self.grayBytes(expected), luma, "細かい網点は変わる")
        for cap in [nil, 512, 2000] as [Int?] {
            for target in Self.targets {
                let image = try await Self.decode(data, cap: cap, target: target, service: service)
                Self.assertGenericGray(image)
                Self.assertIdentical(image, expected, "cap \(String(describing: cap)) target \(Self.name(target))")
            }
        }
        XCTAssertEqual(service.stats().processedPages, 3 * Self.targets.count)
    }

    /// 無彩色の RGB のページも 1 チャンネルの Generic Gray 2.2 になる(PNG と JPEG)
    func testNeutralRGBPageIsProcessedToGenericGray() async throws {
        let service = Self.service()
        let luma = PrintAppearanceTestPages.mix(width: 384, height: 512)
        for type in [UTType.png, .jpeg] {
            let data = try Self.encode(Self.neutralRGBImage(luma, width: 384, height: 512), as: type,
                                       properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
            let expected = try Self.expected(data, level: .strong, cap: nil)
            let image = try await Self.decode(data, cap: nil, target: DisplayColorTarget(rgb: Self.p3),
                                              service: service, level: .strong)
            Self.assertGenericGray(image)
            Self.assertIdentical(image, expected, type.identifier)
        }
    }

    /// エンジンが 1 画素も変えないページも、処理したページとして同じグレーを返す
    func testUnchangedPageStillComesBackGray() async throws {
        let service = Self.service()
        let flat = PrintAppearanceTestPages.flat(width: 300, height: 420, value: 128)
        let gray = try Self.grayPNG(flat, width: 300, height: 420)
        let rgb = try Self.encode(Self.neutralRGBImage(flat, width: 300, height: 420), as: .png)
        for data in [gray, rgb] {
            let image = try await Self.decode(data, cap: nil, target: DisplayColorTarget(rgb: Self.sRGB),
                                              service: service)
            Self.assertGenericGray(image)
            XCTAssertEqual(Self.grayBytes(image), flat)
        }
        let stats = service.stats()
        XCTAssertEqual(stats.processedPages, 2)
        XCTAssertEqual(stats.unchangedPages, 2)
    }

    /// 上限を超えるページは原寸で処理してから cappedDimensions の大きさへ縮める
    func testPageAboveCapIsProcessedAtFullSizeThenReduced() async throws {
        let service = Self.service()
        let luma = PrintAppearanceTestPages.mix(width: 400, height: 600)
        let data = try Self.grayPNG(luma, width: 400, height: 600)
        for cap in [300, 590, 150] {
            let image = try await Self.decode(data, cap: cap, target: nil, service: service)
            let size = try XCTUnwrap(ImageDecoding.cappedDimensions(width: 400, height: 600, cap: cap))
            XCTAssertEqual(image.width, size.width)
            XCTAssertEqual(image.height, size.height)
            Self.assertGenericGray(image)
            Self.assertIdentical(image, try Self.expected(data, level: .standard, cap: cap), "cap \(cap)")
        }
    }

    // MARK: - 失敗と断り

    /// CPU の経路でも断られたページは決定的な素通し(切ったときと同じ画素)
    func testRefusedPageEqualsImageDecoding() async throws {
        let engine = FakePrintAppearanceEngine()
        engine.fail(with: .unsupportedPage("試験用の断り"))
        let service = Self.service(engine: engine)
        let data = try Self.grayPNG(PrintAppearanceTestPages.screen(width: 300, height: 420, period: 4, angle: 45),
                                    width: 300, height: 420)
        for cap in [nil, 300] as [Int?] {
            let image = try await Self.decode(data, cap: cap, target: DisplayColorTarget(rgb: Self.p3),
                                              service: service)
            let expected = try ImageDecoding.decode(data, maxPixelSize: cap,
                                                    displayTarget: DisplayColorTarget(rgb: Self.p3))
            Self.assertIdentical(image, expected, "cap \(String(describing: cap))")
        }
        XCTAssertEqual(service.stats().refusedPages, 2)
    }

    /// GPU の失敗・作業域の不足・辞退では未処理の画素を返さず、例外のまま返す
    func testFailuresNeverYieldRawPixels() async throws {
        let data = try Self.grayPNG(PrintAppearanceTestPages.screen(width: 300, height: 420, period: 4, angle: 45),
                                    width: 300, height: 420)
        for failure in [PrintAppearanceError.gpuFailed("試験用の失敗"), .allocationFailed("試験用の不足")] {
            let engine = FakePrintAppearanceEngine()
            engine.fail(with: failure)
            let service = Self.service(engine: engine)
            do {
                _ = try await Self.decode(data, cap: nil, target: nil, service: service)
                XCTFail("\(failure): 画像が返った")
            } catch let error as PrintAppearanceError {
                XCTAssertEqual(error, failure)
            }
        }
        let engine = FakePrintAppearanceEngine()
        let service = Self.service(engine: engine)
        let ticket = PrintAppearanceTicket(book: ObjectIdentifier(self), isPrefetch: true)
        ticket.decline()
        do {
            _ = try await Self.decode(data, cap: nil, target: nil, service: service,
                                      request: PrintAppearanceRequest(level: .standard, ticket: ticket))
            XCTFail("辞退した読み込みが画像を返した")
        } catch {
            XCTAssertTrue(error is PrefetchDecodeGate.Declined, "\(error)")
        }
        XCTAssertEqual(engine.calls, [])
    }

    // MARK: - 補助

    private static func service(engine: FakePrintAppearanceEngine? = nil) -> PrintAppearanceService {
        var configuration = PrintAppearanceService.Configuration()
        configuration.maxPixels = 16_000_000
        return PrintAppearanceService(
            configuration: configuration,
            makeEngine: {
                if let engine { return engine }
                return PrintAppearanceEngine(mode: .cpuOnly)
            },
            power: FixedPowerState(), pressure: FixedMemoryPressure(), center: NotificationCenter(),
            scheduler: DelayedScheduler { _, _ in {} })
    }

    /// 要求と表示先を立ててデコードの入口を呼ぶ(本の読み込みと同じタスクローカルの経路)
    private static func decode(_ data: Data, cap: Int?, target: DisplayColorTarget?,
                               service: PrintAppearanceService, level: PrintAppearanceLevel = .standard,
                               request: PrintAppearanceRequest? = nil) async throws -> CGImage {
        try await PageRequestIntent.$displayColorTarget.withValue(target) {
            try await PageRequestIntent.$printAppearance.withValue(request ?? PrintAppearanceRequest(level: level)) {
                try await PageImageDecoding.decode(data, maxPixelSize: cap, service: service)
            }
        }
    }

    /// prepare + CPU の厳密な経路の process(+ 上限を超えれば reduce)で作った期待値
    private static func expected(_ data: Data, level: PrintAppearanceLevel, cap: Int?) throws -> CGImage {
        guard case .ready(let page) = try PrintAppearance.prepare(data, maxPixels: 16_000_000) else {
            XCTFail("処理するはずのページが素通し")
            throw PrintAppearanceError.invalidPage("素通し")
        }
        var gray = try PrintAppearanceEngine(mode: .cpuOnly).process(page, level: level, threads: 4)
        if let cap, max(gray.width, gray.height) > cap {
            let size = try XCTUnwrap(ImageDecoding.cappedDimensions(width: gray.width, height: gray.height, cap: cap))
            gray = try PrintAppearance.reduce(gray, width: size.width, height: size.height)
        }
        return try XCTUnwrap(gray.makeImage())
    }

    private static func name(_ target: DisplayColorTarget?) -> String {
        guard let target else { return "nil" }
        return target.rgb == p3 ? "P3" : "sRGB"
    }

    /// 形式と、行の詰め物を除いた画素のバイトが同じ
    private static func assertIdentical(_ image: CGImage, _ expected: CGImage, _ message: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(image.width, expected.width, message, file: file, line: line)
        XCTAssertEqual(image.height, expected.height, message, file: file, line: line)
        XCTAssertEqual(image.bitsPerComponent, expected.bitsPerComponent, message, file: file, line: line)
        XCTAssertEqual(image.bitsPerPixel, expected.bitsPerPixel, message, file: file, line: line)
        XCTAssertEqual(image.bitmapInfo.rawValue, expected.bitmapInfo.rawValue, message, file: file, line: line)
        XCTAssertEqual(image.colorSpace, expected.colorSpace, message, file: file, line: line)
        XCTAssertEqual(rows(image), rows(expected), message, file: file, line: line)
    }

    private static func assertGenericGray(_ image: CGImage, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(image.bitsPerComponent, 8, file: file, line: line)
        XCTAssertEqual(image.bitsPerPixel, 8, file: file, line: line)
        XCTAssertEqual(image.alphaInfo, .none, file: file, line: line)
        XCTAssertEqual(image.colorSpace?.name as String?, CGColorSpace.genericGrayGamma2_2 as String,
                       file: file, line: line)
    }

    /// 行の詰め物を除いた画素のバイト
    private static func rows(_ image: CGImage) -> [UInt8] {
        guard let data = image.dataProvider?.data as Data? else { return [] }
        let rowBytes = image.width * image.bitsPerPixel / 8
        var out = [UInt8]()
        out.reserveCapacity(rowBytes * image.height)
        for y in 0..<image.height {
            out += data[(y * image.bytesPerRow)..<(y * image.bytesPerRow + rowBytes)]
        }
        return out
    }

    private static func grayBytes(_ image: CGImage) -> [UInt8] {
        XCTAssertEqual(image.bitsPerPixel, 8)
        return rows(image)
    }

    private static func image(width: Int, height: Int, bitsPerPixel: Int, space: CGColorSpace,
                              alpha: CGImageAlphaInfo, bytes: [UInt8]) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: bitsPerPixel,
                                     bytesPerRow: width * bitsPerPixel / 8, space: space,
                                     bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue), provider: provider,
                                     decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private static func grayPNG(_ values: [UInt8], width: Int, height: Int) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        return try encode(image(width: width, height: height, bitsPerPixel: 8, space: space, alpha: .none,
                                bytes: values), as: .png)
    }

    private static func neutralRGBImage(_ values: [UInt8], width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: values.count * 4)
        for i in 0..<values.count {
            bytes[4 * i] = values[i]
            bytes[4 * i + 1] = values[i]
            bytes[4 * i + 2] = values[i]
        }
        return try image(width: width, height: height, bitsPerPixel: 32, space: sRGB, alpha: .noneSkipLast,
                         bytes: bytes)
    }

    /// 赤・緑・青のなめらかな勾配(ほぼ全画素が色あり)
    private static func colourImage(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = 4 * (y * width + x)
                bytes[i] = UInt8(x * 255 / max(1, width - 1))
                bytes[i + 1] = UInt8(y * 255 / max(1, height - 1))
                bytes[i + 2] = UInt8((x + y) % 256)
            }
        }
        return try image(width: width, height: height, bitsPerPixel: 32, space: sRGB, alpha: .noneSkipLast,
                         bytes: bytes)
    }

    private static func colourJPEG(width: Int, height: Int) throws -> Data {
        try encode(colourImage(width: width, height: height), as: .jpeg,
                   properties: [kCGImageDestinationLossyCompressionQuality: 0.85])
    }

    private static func colourPNG(width: Int, height: Int) throws -> Data {
        try encode(colourImage(width: width, height: height), as: .png)
    }

    /// 灰色の上に半透明の帯がある RGBA の PNG
    private static func transparentPNG(width: Int, height: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = 4 * (y * width + x)
                let alpha: UInt8 = y < height / 4 ? 128 : 255
                let value = UInt8((x + y) % 200)
                let premultiplied = UInt8(Int(value) * Int(alpha) / 255)
                bytes[i] = premultiplied
                bytes[i + 1] = premultiplied
                bytes[i + 2] = premultiplied
                bytes[i + 3] = alpha
            }
        }
        return try encode(image(width: width, height: height, bitsPerPixel: 32, space: sRGB,
                                alpha: .premultipliedLast, bytes: bytes), as: .png)
    }

    private static func encode(_ image: CGImage, as type: UTType, properties: [CFString: Any] = [:]) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
