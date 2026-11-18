import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import cooViewer
@testable import PrintAppearanceKit

/// ページのデコードの入口の検査(設計書 §5): 網点処理の要求がなければ ImageDecoding.decode と同じ画素、
/// 素通しのページは要求があっても同じ画素(上限の内でも外でも)、処理するページは原寸で処理・仕上げしてから
/// 縮めた完成画像(1 チャンネルのグレーのソースは Generic Gray 2.2、RGB のソースは色を保った sRGB の RGB)。
/// 画像はすべてテストの中で合成する。処理の期待値は CPU の厳密な経路のエンジンで prepare + process +
/// recolour を直接呼んで作る(GPU に依存しない)
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

    /// 無彩色の RGB のページは sRGB の RGB のまま R = G = B = L' になる(PNG。JPEG は prepare + process +
    /// recolour と同じバイト)。表示先があればその空間へ、切ったときの RGB のページと同じ変換をかける
    func testNeutralRGBPageStaysRGBWithEqualChannels() async throws {
        let service = Self.service()
        let luma = PrintAppearanceTestPages.mix(width: 384, height: 512)
        for type in [UTType.png, .jpeg] {
            let data = try Self.encode(Self.neutralRGBImage(luma, width: 384, height: 512), as: type,
                                       properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
            let expected = try Self.expected(data, level: .strong, cap: nil)
            let image = try await Self.decode(data, cap: nil, target: nil, service: service, level: .strong)
            Self.assertSRGB(image)
            Self.assertIdentical(image, expected, type.identifier)
            if type == .png {
                let processed = try Self.processedLuma(data, level: .strong)
                XCTAssertNotEqual(processed, luma, "細かい網点は変わる")
                XCTAssertEqual(Self.channels(image), [processed, processed, processed], "R = G = B = L'")
            }
            let p3 = DisplayColorTarget(rgb: Self.p3)
            let converted = try await Self.decode(data, cap: nil, target: p3, service: service, level: .strong)
            Self.assertIdentical(converted, try XCTUnwrap(p3.converted(expected)), "\(type.identifier) P3")
        }
    }

    /// 薄い色の 1 色刷りとクリーム色の紙のページは、デコードの入口からも色を保って返る:
    /// prepare + process + recolour と同じバイトで、ファイルの各画素のチャンネルの差を保つ(収めた画素を除く)
    func testTintedPagesKeepTheirColourThroughDecode() async throws {
        let service = Self.service()
        let luma = PrintAppearanceTestPages.screen(width: 600, height: 900, period: 3, angle: 45)
        let pages: [(String, [UInt8], [UInt8])] = [
            ("紫の 1 色刷り", PrintAppearanceTestPages.purpleInk, PrintAppearanceTestPages.whitePaper),
            ("クリーム色の紙", PrintAppearanceTestPages.blackInk, PrintAppearanceTestPages.creamPaper),
        ]
        for (name, ink, paper) in pages {
            let tinted = PrintAppearanceTestPages.tinted(luma, ink: ink, paper: paper)
            let data = try Self.encode(Self.image(width: 600, height: 900, bitsPerPixel: 32, space: Self.sRGB,
                                                  alpha: .noneSkipLast, bytes: tinted), as: .png)
            let image = try await Self.decode(data, cap: nil, target: DisplayColorTarget(rgb: Self.sRGB),
                                              service: service)
            Self.assertSRGB(image)
            Self.assertIdentical(image, try Self.expected(data, level: .standard, cap: nil), name)
            let before = try Self.readyPage(data).luma
            let after = try Self.processedLuma(data, level: .standard)
            let out = Self.channels(image)
            var kept = 0, moved = 0
            for i in 0..<luma.count {
                let s = (Int(tinted[4 * i]), Int(tinted[4 * i + 1]), Int(tinted[4 * i + 2]))
                let o = (Int(out[0][i]), Int(out[1][i]), Int(out[2][i]))
                // 0〜255 に収めた画素(ファイルの値 + d がどれかのチャンネルで範囲を出る)は差が変わり得るので除く
                let d = Int(after[i]) - Int(before[i])
                guard [s.0 + d, s.1 + d, s.2 + d].allSatisfy({ (0...255).contains($0) }) else { continue }
                guard o.0 - o.1 == s.0 - s.1, o.1 - o.2 == s.1 - s.2 else {
                    return XCTFail("\(name): チャンネルの差が変わった (\(i)): \(s) → \(o)")
                }
                kept += 1
                if d != 0 { moved += 1 }
            }
            XCTAssertGreaterThan(kept, luma.count * 9 / 10, name)
            XCTAssertGreaterThan(moved, luma.count / 3, "\(name): 細かい網点がまとまっていない")
        }
        XCTAssertEqual(service.stats().processedPages, 2)
    }

    /// エンジンが 1 画素も変えないページも処理したページとして返す: グレーのソースは同じグレー、
    /// RGB のソースは描き直しと同じ RGB
    func testUnchangedPageStillComesBackFinished() async throws {
        let service = Self.service()
        let flat = PrintAppearanceTestPages.flat(width: 300, height: 420, value: 128)
        let gray = try Self.grayPNG(flat, width: 300, height: 420)
        let rgb = try Self.encode(Self.neutralRGBImage(flat, width: 300, height: 420), as: .png)
        let grayImage = try await Self.decode(gray, cap: nil, target: DisplayColorTarget(rgb: Self.sRGB),
                                              service: service)
        Self.assertGenericGray(grayImage)
        XCTAssertEqual(Self.grayBytes(grayImage), flat)
        let rgbImage = try await Self.decode(rgb, cap: nil, target: DisplayColorTarget(rgb: Self.sRGB),
                                             service: service)
        Self.assertSRGB(rgbImage)
        XCTAssertEqual(Self.channels(rgbImage), [flat, flat, flat])
        let stats = service.stats()
        XCTAssertEqual(stats.processedPages, 2)
        XCTAssertEqual(stats.unchangedPages, 2)
    }

    /// 上限を超えるページは原寸で処理・仕上げしてから cappedDimensions の大きさへ縮める
    /// (グレーのソースはグレー、RGB のソースは RGB のまま)
    func testPageAboveCapIsProcessedAtFullSizeThenReduced() async throws {
        let service = Self.service()
        let luma = PrintAppearanceTestPages.mix(width: 400, height: 600)
        let gray = try Self.grayPNG(luma, width: 400, height: 600)
        let tinted = try Self.encode(Self.image(
            width: 400, height: 600, bitsPerPixel: 32, space: Self.sRGB, alpha: .noneSkipLast,
            bytes: PrintAppearanceTestPages.tinted(luma, ink: PrintAppearanceTestPages.purpleInk,
                                                   paper: PrintAppearanceTestPages.whitePaper)), as: .png)
        for (data, isRGB) in [(gray, false), (tinted, true)] {
            for cap in [300, 590, 150] {
                let image = try await Self.decode(data, cap: cap, target: nil, service: service)
                let size = try XCTUnwrap(ImageDecoding.cappedDimensions(width: 400, height: 600, cap: cap))
                XCTAssertEqual(image.width, size.width)
                XCTAssertEqual(image.height, size.height)
                if isRGB { Self.assertSRGB(image) } else { Self.assertGenericGray(image) }
                Self.assertIdentical(image, try Self.expected(data, level: .standard, cap: cap),
                                     "cap \(cap) RGB \(isRGB)")
            }
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

    // MARK: - 作業域の予約

    /// 表示のページ(表示の券・券のないルーペ)はデコードの前にヘッダの大きさで作業域を予約し、
    /// 先読みのページは予約しない。グレーのヘッダでないページは、まだ 1 ページも処理していなければ予約しない
    func testDisplayPagesReserveStoresBeforeDecode() async throws {
        let gray = try Self.grayPNG(PrintAppearanceTestPages.screen(width: 300, height: 420, period: 4, angle: 45),
                                    width: 300, height: 420)
        let engine = FakePrintAppearanceEngine()
        let service = Self.service(engine: engine)
        let prefetch = PrintAppearanceTicket(book: ObjectIdentifier(self), isPrefetch: true)
        _ = try await Self.decode(gray, cap: nil, target: nil, service: service,
                                  request: PrintAppearanceRequest(level: .standard, ticket: prefetch))
        XCTAssertEqual(engine.events.filter { $0.hasPrefix("reserve") }, [], "先読みは予約しない")
        let display = PrintAppearanceTicket(book: ObjectIdentifier(self), isPrefetch: false)
        _ = try await Self.decode(gray, cap: nil, target: nil, service: service,
                                  request: PrintAppearanceRequest(level: .standard, ticket: display))
        _ = try await Self.decode(gray, cap: 200, target: nil, service: service)
        await service.flushForTesting()
        let events = engine.events.filter { !$0.hasPrefix("release") }
        XCTAssertEqual(events.filter { $0.hasPrefix("reserve") }.count, 2)
        XCTAssertEqual(events.first { $0.hasPrefix("reserve") }?.hasPrefix("reserve(300x420,"), true)
        // 予約はそのページの仕事より先に積まれる
        let firstReserve = try XCTUnwrap(events.firstIndex { $0.hasPrefix("reserve") })
        XCTAssertEqual(events[firstReserve + 1].hasPrefix("process"), true, "\(events)")

        // RGB のヘッダのページは、直前の RGB のソースのページを処理したときだけ予約する: 最初の RGB のページと
        // 色のページの次は予約せず、色を保って処理したページの次は予約する
        let fresh = FakePrintAppearanceEngine()
        let freshService = Self.service(engine: fresh)
        let colour = try Self.colourJPEG(width: 600, height: 800)
        let neutral = try Self.encode(Self.neutralRGBImage(
            PrintAppearanceTestPages.screen(width: 300, height: 420, period: 4, angle: 45), width: 300, height: 420),
            as: .png)
        _ = try await Self.decode(colour, cap: nil, target: nil, service: freshService)
        await freshService.flushForTesting()
        XCTAssertEqual(fresh.events, [], "色のページになりうるページで使わない作業域を持たない")
        _ = try await Self.decode(neutral, cap: nil, target: nil, service: freshService)
        await freshService.flushForTesting()
        XCTAssertEqual(fresh.events.filter { $0.hasPrefix("reserve") }, [], "最初の RGB のページは予約しない")
        _ = try await Self.decode(neutral, cap: nil, target: nil, service: freshService)
        await freshService.flushForTesting()
        XCTAssertEqual(fresh.events.filter { $0.hasPrefix("reserve") }.count, 1, "処理した RGB のページの次は予約する")
        // 処理した RGB のページの次に来た色のページ自体は予約する(デコードするまで色と分からない)
        _ = try await Self.decode(colour, cap: nil, target: nil, service: freshService)
        await freshService.flushForTesting()
        XCTAssertEqual(fresh.events.filter { $0.hasPrefix("reserve") }.count, 2)
        _ = try await Self.decode(neutral, cap: nil, target: nil, service: freshService)
        await freshService.flushForTesting()
        XCTAssertEqual(fresh.events.filter { $0.hasPrefix("reserve") }.count, 2, "色のページの次は予約しない")
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

    /// prepare + CPU の厳密な経路の process + recolour(+ 上限を超えれば reduce)で作った期待値
    private static func expected(_ data: Data, level: PrintAppearanceLevel, cap: Int?) throws -> CGImage {
        let page = try readyPage(data)
        let gray = try PrintAppearanceEngine(mode: .cpuOnly).process(page, level: level, threads: 4)
        var output = try PrintAppearance.recolour(page, processed: gray)
        if let cap, max(output.width, output.height) > cap {
            let size = try XCTUnwrap(ImageDecoding.cappedDimensions(width: output.width, height: output.height,
                                                                    cap: cap))
            output = try PrintAppearance.reduce(output, width: size.width, height: size.height)
        }
        return try XCTUnwrap(output.makeImage())
    }

    /// prepare + CPU の厳密な経路の process のエンジンの出力 L'(行の詰め物なし)
    private static func processedLuma(_ data: Data, level: PrintAppearanceLevel) throws -> [UInt8] {
        let gray = try PrintAppearanceEngine(mode: .cpuOnly).process(try readyPage(data), level: level, threads: 4)
        guard let image = gray.makeImage() else { throw PrintAppearanceError.invalidPage("画像化") }
        return rows(image)
    }

    private static func readyPage(_ data: Data) throws -> PrintAppearancePage {
        guard case .ready(let page) = try PrintAppearance.prepare(data, maxPixels: 16_000_000) else {
            XCTFail("処理するはずのページが素通し")
            throw PrintAppearanceError.invalidPage("素通し")
        }
        return page
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

    /// 色を保った完成画像の形式: sRGB の 8 bit、1 画素 4 バイト(4 番目は使わない)
    private static func assertSRGB(_ image: CGImage, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(image.bitsPerComponent, 8, file: file, line: line)
        XCTAssertEqual(image.bitsPerPixel, 32, file: file, line: line)
        XCTAssertEqual(image.alphaInfo, .noneSkipLast, file: file, line: line)
        XCTAssertEqual(image.colorSpace?.name as String?, CGColorSpace.sRGB as String, file: file, line: line)
    }

    /// sRGB の完成画像の R・G・B の面(行の詰め物と 4 番目を除く)
    private static func channels(_ image: CGImage) -> [[UInt8]] {
        XCTAssertEqual(image.bitsPerPixel, 32)
        let bytes = rows(image)
        var planes = [[UInt8]](repeating: [], count: 3)
        for c in 0..<3 { planes[c] = stride(from: c, to: bytes.count, by: 4).map { bytes[$0] } }
        return planes
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
