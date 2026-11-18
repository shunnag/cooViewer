import Accelerate
import CoreGraphics
import Foundation

// 完成画像の仕上げ(設計書 §5): エンジンの出力(輝度 L')をファイルの色に戻し、必要なら縮める。
// 1 画素ずつの処理はすべてここに置く(アプリの Debug 構成は最適化なしで、そこで回すと遅いため)。
//
// 変えるのは明るさだけ。RGB のソースは prepare の sRGB の描き直し (R, G, B) と輝度 L から
//   d = L' - L、出力 = (clamp(R + d), clamp(G + d), clamp(B + d))(0〜255)
// とする。輝度は Y = (299 R + 587 G + 114 B + 500) / 1000 で重みの和が 1000 なので、どのチャンネルも
// 0〜255 に収める必要のない画素では Y(出力) = L + d = L' がちょうど成り立つ。L' == L の画素は描き直しのまま、
// R = G = B のページは R = G = B = L'(グレーの出力と同じ階調)になり、チャンネルの差 R - G・G - B は
// 収めた画素を除いて保たれる。エンジンと、その検証済みの実装との一致(L' のバイト)には触れない。

enum PageOutput {
    static func recolour(_ page: PrintAppearancePage,
                         processed: PrintAppearanceGray) throws -> PrintAppearanceOutput {
        guard processed.width == page.width, processed.height == page.height else {
            throw PrintAppearanceError.invalidPage(
                "処理結果 \(processed.width)x\(processed.height) がページ \(page.width)x\(page.height) と一致しない")
        }
        guard let redraw = page.redraw else { return .gray(processed) }
        let w = page.width, h = page.height
        guard redraw.width == w, redraw.height == h else {
            throw PrintAppearanceError.invalidPage("描き直しの大きさがページと一致しない")
        }
        let rowBytes = PrintAppearanceRGB.alignedRowBytes(w)
        // 仮想記憶に置き、手放したらすぐ OS へ返す(設計書 §2.3)
        let pixels = PageMemory.zeroedData(byteCount: rowBytes * h) { out in
            processed.pixels.withUnsafeBytes { after in
                page.withLuma { before in
                    let lAfter = after.bindMemory(to: UInt8.self).baseAddress!
                    let lBefore = before.baseAddress!
                    for y in 0..<h {
                        let src = redraw.base + y * redraw.bytesPerRow
                        let row = out + y * rowBytes
                        let a = lAfter + y * processed.bytesPerRow
                        let b = lBefore + y * w
                        for x in 0..<w {
                            let d = Int(a[x]) - Int(b[x])
                            let s = src + x * 4, o = row + x * 4
                            o[0] = clampByte(Int(s[0]) + d)
                            o[1] = clampByte(Int(s[1]) + d)
                            o[2] = clampByte(Int(s[2]) + d)
                            o[3] = 255
                        }
                    }
                }
            }
        }
        return .rgb(PrintAppearanceRGB(width: w, height: h, bytesPerRow: rowBytes, pixels: pixels,
                                       changed: processed.changed))
    }

    @inline(__always)
    private static func clampByte(_ v: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: min(255, max(0, v)))
    }

    // MARK: - 縮小

    /// グレーの縮小と同じ高品質の再標本化(vImage)。ARGB8888 の関数は 4 つのチャンネルを同じ核で独立に
    /// 再標本化し、どれも透明度として扱わない(Planar8 をチャンネルごとにかけたのと同じバイト。検査で確かめる)。
    /// 4 番目の欄は 255 のまま保たれる。出力と vImage の一時領域は仮想記憶に置く(設計書 §2.3)
    static func reduce(_ page: PrintAppearanceRGB, width: Int, height: Int) throws -> PrintAppearanceRGB {
        guard width > 0, height > 0 else { throw PrintAppearanceError.invalidPage("縮小先の大きさ \(width)x\(height)") }
        if width == page.width && height == page.height { return page }
        let rowBytes = PrintAppearanceRGB.alignedRowBytes(width)
        let pixels = try PageMemory.zeroedData(byteCount: rowBytes * height) { dst in
            let error = page.pixels.withUnsafeBytes { src in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!),
                                      height: vImagePixelCount(page.height), width: vImagePixelCount(page.width),
                                      rowBytes: page.bytesPerRow)
                var d = vImage_Buffer(data: dst, height: vImagePixelCount(height),
                                      width: vImagePixelCount(width), rowBytes: rowBytes)
                let flags = vImage_Flags(kvImageHighQualityResampling)
                return PageInput.withScaleTemp(
                    vImageScale_ARGB8888(&s, &d, nil, flags | vImage_Flags(kvImageGetTempBufferSize))) {
                    vImageScale_ARGB8888(&s, &d, $0, flags)
                }
            }
            guard error == kvImageNoError else { throw PrintAppearanceError.allocationFailed("vImageScale: \(error)") }
        }
        return PrintAppearanceRGB(width: width, height: height, bytesPerRow: rowBytes, pixels: pixels,
                                  changed: page.changed)
    }
}
