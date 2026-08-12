import Metal
import QuartzCore
import XCTest
@testable import cooViewer

/// ページカールの実描画検証。3D 変換は layer.render(in:) に写らないため、
/// CARenderer(Metal のオフスクリーン合成)で実際に描画して確かめる。
///
/// 座標系の仮定を排するため、**実物の ReaderView**(flipped な layer-backed
/// ビュー)に実経路(snapshotContent)で作った画像を流し込み、
/// 「オーバーレイの描画結果 = ライブ表示の描画結果」をピクセル比較する
/// 自己校正方式にしている。
/// - 終端(progress=1)で全画面がライブ表示と一致 =「裏のページの向き」と
///   位置の整合の回帰テスト
/// - めくり途中は下の帯が上の帯より先に空く =「下の角からめくる」感じ
@MainActor
final class PageCurlRenderTests: XCTestCase {
    private let size = CGSize(width: 200, height: 120)

    /// 4 象限の色分け画像(視覚上: 左上=赤/右上=緑/左下=青/右下=黄)
    private func quadrantImage() -> CGImage {
        let width = Int(size.width)
        let height = Int(size.height)
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func fill(_ rect: CGRect, _ color: CGColor) {
            context.setFillColor(color)
            context.fill(rect)
        }
        let halfW = CGFloat(width) / 2
        let halfH = CGFloat(height) / 2
        // CG の描画座標は下原点: y 上半分の矩形が画像の上側になる
        fill(CGRect(x: 0, y: halfH, width: halfW, height: halfH),
             CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))      // 左上=赤
        fill(CGRect(x: halfW, y: halfH, width: halfW, height: halfH),
             CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))      // 右上=緑
        fill(CGRect(x: 0, y: 0, width: halfW, height: halfH),
             CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))      // 左下=青
        fill(CGRect(x: halfW, y: 0, width: halfW, height: halfH),
             CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1))      // 右下=黄
        return context.makeImage()!
    }

    private func solidImage(gray: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        return context.makeImage()!
    }

    /// 4 象限ページを表示した実物の ReaderView(ウインドウなしでレイアウト済み)
    private func makeReaderView() -> ReaderView {
        let view = ReaderView(frame: CGRect(origin: .zero, size: size))
        view.setPages([quadrantImage()], readsFromLeft: false)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// CARenderer で 1 フレーム描画し、RGBA8 のピクセル列を返す。
    /// GPU 完了を待つ API が無いため、非透明ピクセルが現れるまで
    /// 短い待ちを挟んで読み直す(全面透明が正解のテストはないため安全)
    private func render(_ root: CALayer) throws -> [UInt8] {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal が使えない環境")
        }
        let width = Int(size.width)
        let height = Int(size.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height,
            mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        let renderer = CARenderer(mtlTexture: texture, options: nil)
        renderer.layer = root
        renderer.bounds = CGRect(origin: .zero, size: size)
        CATransaction.flush()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for _ in 0..<20 {
            renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
            usleep(30_000)
            texture.getBytes(&bytes, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height),
                             mipmapLevel: 0)
            if bytes.contains(where: { $0 != 0 }) {
                return bytes
            }
        }
        return bytes
    }

    private func pixel(_ bytes: [UInt8], x: Int, row: Int)
        -> (r: Int, g: Int, b: Int, a: Int) {
        let offset = (row * Int(size.width) + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]),
                Int(bytes[offset + 2]), Int(bytes[offset + 3]))
    }

    private func roughlyEqual(_ lhs: (r: Int, g: Int, b: Int, a: Int),
                              _ rhs: (r: Int, g: Int, b: Int, a: Int),
                              tolerance: Int = 40) -> Bool {
        abs(lhs.r - rhs.r) <= tolerance && abs(lhs.g - rhs.g) <= tolerance
            && abs(lhs.b - rhs.b) <= tolerance
    }

    // MARK: - テスト本体

    /// 終端(progress=1)でオーバーレイの絵がライブ表示と一致すること
    /// (裏面の向き・位置の整合の回帰テスト)。両リーフ方向で確認する
    func testCurlEndStateMatchesLiveContent() throws {
        for leafOnLeft in [false, true] {
            let view = makeReaderView()
            // 基準: オーバーレイなしのライブ表示
            let reference = try render(view.layer!)
            // 実経路のスナップショットを新内容としてオーバーレイを組む
            let newContent = try XCTUnwrap(view.snapshotContent())
            let overlay = try XCTUnwrap(PageCurlOverlay.makeStatic(
                .init(bounds: view.bounds, leafOnLeft: leafOnLeft,
                      oldContent: solidImage(gray: 0.5),
                      newContent: newContent),
                progress: 1))
            view.layer!.addSublayer(overlay)
            defer { overlay.removeFromSuperlayer() }
            let rendered = try render(view.layer!)

            // 全域の格子サンプルがライブ表示と一致する(ストリップ境界は避ける)
            for x in stride(from: 12, to: Int(size.width), by: 23) {
                for row in stride(from: 8, to: Int(size.height), by: 13) {
                    let got = pixel(rendered, x: x, row: row)
                    let want = pixel(reference, x: x, row: row)
                    XCTAssertTrue(
                        roughlyEqual(got, want),
                        "leafOnLeft=\(leafOnLeft) (\(x),\(row)): " +
                        "got \(got) want \(want)")
                }
            }
        }
    }

    /// めくり途中、着地側(かぶさられて暗くなる側)と表面(リーフ)が
    /// ライブ表示と同じ向き(正立)で見えること。
    /// 「かぶさってくる側のページが上下反転する」の回帰テスト
    func testCurlMidTurnShowsLandingAndFrontUpright() throws {
        for leafOnLeft in [false, true] {
            let view = makeReaderView()
            let reference = try render(view.layer!)
            // 旧内容=実経路のスナップショット(ライブと同じ絵)、新内容=灰色。
            // めくり始めの画面はライブ表示とほぼ同じに見えるはず
            let oldContent = try XCTUnwrap(view.snapshotContent())
            let overlay = try XCTUnwrap(PageCurlOverlay.makeStatic(
                .init(bounds: view.bounds, leafOnLeft: leafOnLeft,
                      oldContent: oldContent,
                      newContent: solidImage(gray: 0.5)),
                progress: 0.1))
            view.layer!.addSublayer(overlay)
            defer { overlay.removeFromSuperlayer() }
            let rendered = try render(view.layer!)

            // 着地側(リーフの反対側)はほぼ全面が旧内容の静止表示
            let landingXs = leafOnLeft ? [150, 170] : [30, 50]
            // リーフ側もめくり始めは表面(旧内容)がほぼ元の位置にある
            // (わずかな傾き・陰があるため許容差を広めにとる)
            let leafXs = leafOnLeft ? [30, 50] : [150, 170]
            for x in landingXs + leafXs {
                for row in [15, Int(size.height) - 15] {
                    let got = pixel(rendered, x: x, row: row)
                    let want = pixel(reference, x: x, row: row)
                    XCTAssertTrue(
                        roughlyEqual(got, want, tolerance: 70),
                        "leafOnLeft=\(leafOnLeft) (\(x),\(row)): " +
                        "got \(got) want \(want)(上下反転すると赤と青が入れ替わる)")
                }
            }
        }
    }

    /// めくり途中(progress=0.35)は「下の角が先行して」空くこと。
    /// リーフ元位置で、ライブ内容(新しいページ)が見えている割合が
    /// 下の帯のほうが上の帯より多い。両リーフ方向で確認する
    func testCurlMidTurnLiftsBottomCornerFirst() throws {
        for leafOnLeft in [false, true] {
            let view = makeReaderView()
            let reference = try render(view.layer!)
            let newContent = try XCTUnwrap(view.snapshotContent())
            // 旧内容は灰色 1 色: 「ライブと一致=空いた」「灰色=まだ覆われている」
            let overlay = try XCTUnwrap(PageCurlOverlay.makeStatic(
                .init(bounds: view.bounds, leafOnLeft: leafOnLeft,
                      oldContent: solidImage(gray: 0.5),
                      newContent: newContent),
                progress: 0.35))
            view.layer!.addSublayer(overlay)
            defer { overlay.removeFromSuperlayer() }
            let rendered = try render(view.layer!)

            // 基準画像の視覚上の上下を色で判定する(左上=赤/左下=青)
            let topRowCandidates = [8, Int(size.height) - 8]
            let topRow = topRowCandidates.first {
                pixel(reference, x: 50, row: $0).r > 150
            } ?? 8
            let bottomRow = topRow == 8 ? Int(size.height) - 8 : 8

            // リーフ元位置の帯(ノド寄りと画面端は避ける)
            let xRange = leafOnLeft
                ? 2..<(Int(size.width) / 2 - 10)
                : (Int(size.width) / 2 + 10)..<(Int(size.width) - 2)
            func revealedCount(row: Int) -> Int {
                xRange.count { x in
                    roughlyEqual(pixel(rendered, x: x, row: row),
                                 pixel(reference, x: x, row: row))
                }
            }
            let topRevealed = revealedCount(row: topRow)
            let bottomRevealed = revealedCount(row: bottomRow)
            XCTAssertGreaterThan(bottomRevealed, topRevealed,
                "leafOnLeft=\(leafOnLeft): 下の角が先に空くはず" +
                "(上=\(topRevealed) 下=\(bottomRevealed))")
        }
    }
}
