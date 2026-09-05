import AppKit
import ImageIO
import WebKit
import XCTest
@testable import Washi

/// cooViewer-oxr.78: ダークテーマの外字画像分類と SVG 既定色を実描画で検証する。
@MainActor
final class DarkGlyphRenderingTests: XCTestCase {
    func testDarkThemeRendersGlyphPNGAndDefaultFillSVGLight() async throws {
        let glyphURL = try Self.dataURL(
            width: 32, height: 32, color: .black,
            fill: CGRect(x: 8, y: 4, width: 16, height: 24))
        let photoURL = try Self.dataURL(
            width: 600, height: 400,
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            fill: CGRect(x: 0, y: 0, width: 600, height: 400))
        let body = """
            <p style="font-size:20px;margin:0">前
              <img id="glyph" src="\(glyphURL)" alt="外字"/>後
              <svg id="inline-svg" xmlns="http://www.w3.org/2000/svg"
                   width="32" height="32" viewBox="0 0 32 32">
                <path id="default-fill" d="M0 0h32v32H0z"/>
              </svg>
            </p>
            <figure style="margin:8px 0 0">
              <img id="photo" class="gaiji" src="\(photoURL)"
                   style="width:300px;height:200px" alt="写真"/>
            </figure>
            <div style="position:absolute;visibility:hidden">
              <svg xmlns="http://www.w3.org/2000/svg" fill="#123456">
                <path id="inherited-fill" d="M0 0h1v1H0z"/>
              </svg>
              <svg xmlns="http://www.w3.org/2000/svg">
                <g fill="none">
                  <path id="inherited-none" d="M0 0h1v1H0z"/>
                </g>
              </svg>
              <svg xmlns="http://www.w3.org/2000/svg">
                <path id="black-stroke" fill="none" stroke="#000"
                      d="M0 0h1v1H0z"/>
                <path id="colored-stroke" fill="none" stroke="#008000"
                      d="M0 0h1v1H0z"/>
                <path id="styled-stroke" fill="none" stroke="black"
                      style="stroke:#ff0000" d="M0 0h1v1H0z"/>
              </svg>
            </div>
            """
        let harness = try ReaderScriptTestHarness(
            entries: EPUBFixtures.singleSpineEntries(bodyHTML: body))
        defer { harness.close() }
        try await harness.load()
        let decoded: Bool = try await harness.evaluate("""
            await Promise.all(Array.from(document.images).map(image => image.decode()));
            return Array.from(document.images).every(image => image.complete);
            """)
        XCTAssertTrue(decoded)

        var settings = EPUBReaderSettings()
        settings.theme = .dark
        try await setup(harness, css: settings.composedUserCSS(isDark: true))
        let state: String = try await call(harness, """
            const glyph = document.getElementById('glyph');
            const photo = document.getElementById('photo');
            const path = document.getElementById('default-fill');
            return [glyph.classList.contains('washi-glyph'),
                    getComputedStyle(glyph).filter,
                    photo.classList.contains('washi-glyph'),
                    getComputedStyle(photo).filter,
                    photo.naturalWidth, photo.naturalHeight,
                    getComputedStyle(path).fill].join('|');
            """)
        let components = state.split(separator: "|", omittingEmptySubsequences: false)
        XCTAssertEqual(components.count, 7)
        guard components.count == 7 else { return }
        XCTAssertEqual(components[0], "true")
        XCTAssertNotEqual(components[1], "none")
        XCTAssertEqual(components[2], "false")
        XCTAssertEqual(components[3], "none")
        XCTAssertEqual(components[4], "600")
        XCTAssertEqual(components[5], "400")
        XCTAssertNotEqual(components[6], "rgb(0, 0, 0)")

        // cooViewer-oxr.78: 既定色だけを補い、祖先の明示 fill と
        // black 以外の stroke は書籍指定のまま残す。
        let svgCascade: String = try await call(harness, """
            const inherited = getComputedStyle(
                document.getElementById('inherited-fill')).fill;
            const inheritedNone = getComputedStyle(
                document.getElementById('inherited-none')).fill;
            const black = document.getElementById('black-stroke');
            const colored = document.getElementById('colored-stroke');
            const styled = document.getElementById('styled-stroke');
            return [inherited, inheritedNone,
                    getComputedStyle(black).stroke
                        === getComputedStyle(black).color,
                    getComputedStyle(colored).stroke,
                    getComputedStyle(styled).stroke].join('|');
            """)
        XCTAssertEqual(
            svgCascade,
            "rgb(18, 52, 86)|none|true|rgb(0, 128, 0)|rgb(255, 0, 0)")

        let snapshot = try await snapshot(of: harness)
        let glyph = try await rect(id: "glyph", in: harness)
        let inlineSVG = try await rect(id: "inline-svg", in: harness)
        let photo = try await rect(id: "photo", in: harness)
        let glyphColor = try color(at: glyph, in: snapshot, view: harness.webView)
        let svgColor = try color(at: inlineSVG, in: snapshot, view: harness.webView)
        let photoColor = try color(at: photo, in: snapshot, view: harness.webView)
        XCTAssertGreaterThan(glyphColor.redComponent * 255, 200)
        XCTAssertGreaterThan(glyphColor.greenComponent * 255, 200)
        XCTAssertGreaterThan(glyphColor.blueComponent * 255, 200)
        XCTAssertGreaterThan(svgColor.redComponent * 255, 200)
        XCTAssertGreaterThan(svgColor.greenComponent * 255, 200)
        XCTAssertGreaterThan(svgColor.blueComponent * 255, 200)
        XCTAssertGreaterThan(photoColor.redComponent * 255, 200)
        XCTAssertLessThan(photoColor.greenComponent * 255, 50)
        XCTAssertLessThan(photoColor.blueComponent * 255, 50)

        let background = try color(
            at: CGPoint(x: 620, y: 380), in: snapshot, view: harness.webView)
        XCTAssertEqual(background.redComponent * 255, 26, accuracy: 8)
        XCTAssertEqual(background.greenComponent * 255, 26, accuracy: 8)
        XCTAssertEqual(background.blueComponent * 255, 28, accuracy: 8)
    }

    func testGlyphImageOptOutLeavesPNGBlack() async throws {
        let glyphURL = try Self.dataURL(
            width: 32, height: 32, color: .black,
            fill: CGRect(x: 8, y: 4, width: 16, height: 24))
        let harness = try ReaderScriptTestHarness(entries:
            EPUBFixtures.singleSpineEntries(bodyHTML:
                "<p style=\"font-size:20px;margin:0\">前<img id=\"glyph\" src=\"\(glyphURL)\"/>後</p>"))
        defer { harness.close() }
        try await harness.load()
        let _: Bool = try await harness.evaluate(
            "await document.getElementById('glyph').decode(); return true;")

        var settings = EPUBReaderSettings()
        settings.theme = .dark
        settings.invertsGlyphImagesInDark = false
        try await setup(harness, css: settings.composedUserCSS(isDark: true))
        let state: String = try await harness.evaluate("""
            const glyph = document.getElementById('glyph');
            return String(glyph.classList.contains('washi-glyph')) + '|'
                + getComputedStyle(glyph).filter;
            """)
        XCTAssertEqual(state, "true|none")

        let snapshot = try await snapshot(of: harness)
        let glyph = try await rect(id: "glyph", in: harness)
        let color = try color(at: glyph, in: snapshot, view: harness.webView)
        XCTAssertLessThan(color.redComponent * 255, 50)
        XCTAssertLessThan(color.greenComponent * 255, 50)
        XCTAssertLessThan(color.blueComponent * 255, 50)
    }

    func testGlyphClassificationRerunsAfterDecodeSettingsAndRepagination() async throws {
        let glyphURL = try Self.dataURL(
            width: 32, height: 32, color: .black,
            fill: CGRect(x: 8, y: 4, width: 16, height: 24))
        let harness = try ReaderScriptTestHarness(entries:
            EPUBFixtures.singleSpineEntries(bodyHTML:
                "<p style=\"font-size:20px\">前<img id=\"glyph\" src=\"\(glyphURL)\"/>後</p>"))
        defer { harness.close() }
        try await harness.load()
        var settings = EPUBReaderSettings()
        settings.theme = .dark
        let css = settings.composedUserCSS(isDark: true)

        let states: String = try await call(harness, """
            const image = document.getElementById('glyph');
            let finishDecode = null;
            Object.defineProperties(image, {
                naturalWidth: {configurable:true, value:0},
                naturalHeight: {configurable:true, value:0},
                decode: {configurable:true, value:function () {
                    return new Promise(resolve => { finishDecode = resolve; });
                }}
            });
            const options = {width:640,height:400,gap:24,spread:false,
                gutter:48,fixedLayout:false,keysEnabled:false,userCSS:css};
            __washi.setup(options);
            const beforeDecode = image.classList.contains('washi-glyph');
            Object.defineProperties(image, {
                naturalWidth: {configurable:true, value:32},
                naturalHeight: {configurable:true, value:32}
            });
            finishDecode();
            await Promise.resolve();
            await Promise.resolve();
            const afterDecode = image.classList.contains('washi-glyph');

            image.classList.remove('washi-glyph');
            image.removeAttribute('data-washi-glyph-classified');
            __washi.setUserCSS(css);
            const afterSettings = image.classList.contains('washi-glyph');

            image.classList.remove('washi-glyph');
            image.removeAttribute('data-washi-glyph-classified');
            __washi.repaginate(options);
            const afterRepagination = image.classList.contains('washi-glyph');
            return [beforeDecode, afterDecode, afterSettings, afterRepagination]
                .join('|');
            """, arguments: ["css": css])
        XCTAssertEqual(states, "false|true|true|true")
    }

    func testGlyphImageSettingDoesNotChangePaginationCacheKey() {
        let enabled = EPUBReaderSettings()
        XCTAssertTrue(enabled.invertsGlyphImagesInDark)
        var disabled = enabled
        disabled.invertsGlyphImagesInDark = false
        let size = CGSize(width: 640, height: 400)
        XCTAssertEqual(
            EPUBScreenMetrics(viewportSize: size, settings: enabled).cacheKey,
            EPUBScreenMetrics(viewportSize: size, settings: disabled).cacheKey)
        XCTAssertTrue(enabled.composedUserCSS(isDark: true).contains(
            "img.washi-glyph { filter: invert(1) !important; }"))
        XCTAssertFalse(disabled.composedUserCSS(isDark: true).contains(
            "img.washi-glyph { filter: invert(1) !important; }"))
        XCTAssertTrue(disabled.composedUserCSS(isDark: true).contains(
            "fill: currentColor"))
        XCTAssertFalse(enabled.composedUserCSS(isDark: false).contains(
            "img.washi-glyph"))
        XCTAssertFalse(enabled.composedUserCSS(isDark: false).contains(
            "fill: currentColor"))
    }

    private func setup(_ harness: ReaderScriptTestHarness, css: String) async throws {
        let _: Int = try await call(harness, """
            const result = __washi.setup({width:640,height:400,gap:24,
                spread:false,gutter:48,fixedLayout:false,keysEnabled:false,
                userCSS:css});
            return result.pageCount;
            """, arguments: ["css": css])
    }

    private func call<T: Sendable>(
        _ harness: ReaderScriptTestHarness,
        _ body: String,
        arguments: [String: Any] = [:]
    ) async throws -> T {
        let result = try await harness.webView.callAsyncJavaScript(
            body, arguments: arguments, in: nil,
            contentWorld: EPUBReaderView.washiWorld)
        return try XCTUnwrap(result as? T)
    }

    private func snapshot(of harness: ReaderScriptTestHarness) async throws
        -> NSBitmapImageRep {
        // cooViewer-oxr.78: 画面外 window では requestAnimationFrame が
        // 発火しないため待たず、直前の image.decode と snapshot の
        // afterScreenUpdates に描画確定を任せる。
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image = try await harness.webView.takeSnapshot(
            configuration: configuration)
        let data = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: data))
    }

    private func rect(id: String, in harness: ReaderScriptTestHarness) async throws
        -> CGRect {
        let values: [String: Double] = try await call(harness, """
            const rect = document.getElementById(elementID).getBoundingClientRect();
            return {x:rect.x,y:rect.y,width:rect.width,height:rect.height};
            """, arguments: ["elementID": id])
        return CGRect(
            x: try XCTUnwrap(values["x"]),
            y: try XCTUnwrap(values["y"]),
            width: try XCTUnwrap(values["width"]),
            height: try XCTUnwrap(values["height"]))
    }

    private func color(
        at rect: CGRect, in bitmap: NSBitmapImageRep, view: WKWebView
    ) throws -> NSColor {
        try color(at: CGPoint(x: rect.midX, y: rect.midY),
                  in: bitmap, view: view)
    }

    private func color(
        at point: CGPoint, in bitmap: NSBitmapImageRep, view: WKWebView
    ) throws -> NSColor {
        // cooViewer-oxr.78: レイアウト崩れで要素が viewport 外へ出た場合、
        // 端の無関係な画素へ丸めずテストを明示的に失敗させる。
        let point = try XCTUnwrap(
            view.bounds.contains(point) ? point : nil,
            "Pixel sample \(point) is outside the web-view viewport")
        let scaleX = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        let x = Int(point.x * scaleX)
        let y = Int(point.y * scaleY)
        let sampled = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
        // cooViewer-oxr.78: colorAt が返す NSCalibratedRGB の成分は
        // 画素の符号化値そのものなので、sRGB へ再変換してガンマを重ねない。
        return sampled
    }

    private static func dataURL(
        width: Int, height: Int, color: CGColor, fill: CGRect
    ) throws -> String {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(color)
        context.fill(fill)
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return "data:image/png;base64,\((output as Data).base64EncodedString())"
    }
}
