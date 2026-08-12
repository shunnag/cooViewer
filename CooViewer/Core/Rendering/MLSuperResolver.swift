import CoreGraphics
import CoreML
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 圧縮ノイズ低減「最高」の実体: Real-ESRGAN x4plus anime 6B(CoreML)。
/// アニメ・マンガ絵向けの超解像 GAN で、JPEG ノイズを除去しつつ 4 倍へ
/// 拡大する(その後の表示縮小で実質的な画質向上になる)。waifu2x(強)より
/// 大幅に高品質だが重い(1 タイル 256×256 を約 46ms、1 ページ数秒)。
///
/// モデル(約 9MB)はアプリに同梱せず、「最高」を初回選択して同意した後の
/// **必要時にのみ**本リポジトリのリリース資産(models-1 タグ)から
/// ダウンロードする。元モデルは xinntao/Real-ESRGAN(BSD-3-Clause)で、
/// CoreML への変換は Scripts/convert-realesrgan.py(fp16、PyTorch との
/// パリティ最大誤差 0.003 を確認済み)。
///
/// 処理が重いため結果は HEIC でディスクキャッシュし
/// (Caches/jp.coo.cooViewer/SuperRes/)、サムネイルと同じ保持日数で
/// 起動時にトリムする。未導入・失敗・元画像が大きすぎる場合は nil を
/// 返し、呼び出し側(ImageResampler)が「強」相当へフォールバックする。
actor MLSuperResolver {
    static let shared = MLSuperResolver()

    /// 同意ダイアログに表示する概算サイズ
    static let modelSizeDescription = "9 MB"
    /// この長辺(px)を超える元画像は処理しない(タイル数と時間が伸び
    /// すぎるため「強」へフォールバックさせる)。十分に大きい画像は
    /// そもそも超解像の恩恵が小さい
    static let maxSourceEdge = 2048
    /// 拡大倍率(モデル固有)
    static let scale = 4
    /// モデル入力の一辺(px。モデル固有)
    static let inputSide = 256
    /// タイル継ぎ目の文脈マージン(入力側 px)。畳み込みの受容野による
    /// タイル端の乱れを、隣接タイルと重ねて捨てることで消す
    static let margin = 8
    /// 1 タイルで確定する内容領域の一辺(入力側 px)
    static let contentSide = inputSide - 2 * margin

    private let installer = MLModelInstaller(
        specification: .init(
            downloadURL: URL(string:
                "https://github.com/shunnag/cooViewer/releases/download/models-1/realesrgan_anime6b_256.mlmodel")!,
            sha256: "d33e0d579cd4deb3595cffa797f57f5aed0ec093ac7d8c86ea0bac088fc8fb63",
            fileName: "realesrgan_anime6b_256.mlmodel"),
        status: MLModelInstallStatus.superResolution)

    // MARK: - 導入

    /// モデルを使える状態にする(必要ならダウンロード→検証→コンパイル→ロード)
    @discardableResult
    func ensureModel() async -> Bool {
        await installer.ensureModel() != nil
    }

    // MARK: - 推論

    /// image を 4 倍へ超解像した画像を返す。cacheKey を渡すとディスク
    /// キャッシュを使う(キーは呼び出し側が画像サイズまで含めて一意にする)。
    /// 大きすぎる画像・モデル未導入・失敗時は nil
    func upscale(_ image: CGImage, cacheKey: String?) async -> CGImage? {
        guard image.width > 0, image.height > 0,
              max(image.width, image.height) <= Self.maxSourceEdge else {
            return nil
        }
        if let cacheKey, let cached = Self.readDiskCache(for: cacheKey) {
            return cached
        }
        if ProcessInfo.processInfo.environment["COO_TRACE"] != nil {
            NSLog("SR start %@ (%dx%d)", cacheKey ?? "-", image.width, image.height)
        }
        guard let loaded = await installer.ensureModel() else { return nil }
        guard let result = await runTiled(model: loaded.model, image: image) else {
            return nil
        }
        if let cacheKey {
            Self.writeDiskCache(result, for: cacheKey)
        }
        if ProcessInfo.processInfo.environment["COO_TRACE"] != nil {
            NSLog("SR done %@", cacheKey ?? "-")
        }
        return result
    }

    /// タイル推論の本体(モデルの入出力は変換時と probe で確認済み:
    /// 入力 "input" [1,3,256,256] の 0-1、出力 "output" [1,3,1024,1024])。
    /// 各タイルは周囲 margin px の文脈を含めて推論し、中心の contentSide
    /// 相当だけを出力へ確定する。画像端は端画素の複製で埋める
    private func runTiled(model: MLModel, image: CGImage) async -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let sourceData = { () -> UnsafeMutablePointer<UInt8>? in
                  context.draw(image, in: CGRect(x: 0, y: 0,
                                                 width: width, height: height))
                  return context.data?.assumingMemoryBound(to: UInt8.self)
              }() else { return nil }
        let sourceBytesPerRow = width * 4

        let outWidth = width * Self.scale
        let outHeight = height * Self.scale
        let outBytesPerRow = outWidth * 4
        let outBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: outBytesPerRow * outHeight, alignment: 16)
        let out = outBuffer.assumingMemoryBound(to: UInt8.self)

        guard let input = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: Self.inputSide),
                    NSNumber(value: Self.inputSide)],
            dataType: .float32) else {
            outBuffer.deallocate()
            return nil
        }
        let inputPointer = input.dataPointer.assumingMemoryBound(to: Float.self)
        let planeStride = Self.inputSide * Self.inputSide

        for origin in Self.tileOrigins(width: width, height: height) {
            // 1 タイル約 46ms かかるため、タイル毎に譲歩してキャンセルも見る
            await Task.yield()
            if Task.isCancelled {
                outBuffer.deallocate()
                return nil
            }
            // 入力: 内容領域の周囲 margin を含めて集める。画像端は端画素を複製
            for row in 0..<Self.inputSide {
                let sourceY = min(max(origin.y + row - Self.margin, 0), height - 1)
                for column in 0..<Self.inputSide {
                    let sourceX = min(max(origin.x + column - Self.margin, 0),
                                      width - 1)
                    let pixel = sourceY * sourceBytesPerRow + sourceX * 4
                    let position = row * Self.inputSide + column
                    inputPointer[position] = Float(sourceData[pixel]) / 255
                    inputPointer[planeStride + position] =
                        Float(sourceData[pixel + 1]) / 255
                    inputPointer[planeStride * 2 + position] =
                        Float(sourceData[pixel + 2]) / 255
                }
            }
            guard let provider = try? MLDictionaryFeatureProvider(
                    dictionary: ["input": MLFeatureValue(multiArray: input)]),
                  let prediction = try? Self.predict(model: model,
                                                     provider: provider),
                  let result = prediction.featureValue(for: "output")?
                      .multiArrayValue else {
                outBuffer.deallocate()
                return nil
            }
            Self.writeTile(result, into: out, bytesPerRow: outBytesPerRow,
                           origin: origin, width: width, height: height)
        }

        guard let provider = CGDataProvider(
            dataInfo: nil, data: outBuffer,
            size: outBytesPerRow * outHeight,
            releaseData: { _, data, _ in data.deallocate() }) else {
            outBuffer.deallocate()
            return nil
        }
        return CGImage(
            width: outWidth, height: outHeight,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: outBytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent)
    }

    /// 同期版 prediction の明示呼び出し(async 文脈では await 版へ解決されて
    /// 非 Sendable の MLModel を送ることになるため、同期関数で束ねる)
    private nonisolated static func predict(
        model: MLModel, provider: MLFeatureProvider) throws -> MLFeatureProvider {
        try model.prediction(from: provider)
    }

    /// 出力タイル([1,3,1024,1024]。Float32/Double 両対応)を出力バッファへ書く。
    ///
    /// GAN はタイル毎に平坦部のトーンがごくわずかに揺れるため、マージンを
    /// 捨ててハードに継ぐだけでは Δ1〜2 階調の帯が内容境界に見える(実測)。
    /// そこで各タイルは内容領域に加えて右・下へ margin 分を余計に書き、
    /// 次のタイルが左・上の同じ幅を前のタイルと**線形フェザーで合成**して
    /// 継ぎ目を消す(処理順は行優先なので左・上は常に書き込み済み)
    private static func writeTile(_ result: MLMultiArray,
                                  into out: UnsafeMutablePointer<UInt8>,
                                  bytesPerRow: Int, origin: (x: Int, y: Int),
                                  width: Int, height: Int) {
        let contentWidth = min(contentSide, width - origin.x)
        let contentHeight = min(contentSide, height - origin.y)
        // 右・下への延長幅(ソース px)。画像端では残りに合わせて切り詰める
        let extendRight = min(margin, width - origin.x - contentWidth)
        let extendBottom = min(margin, height - origin.y - contentHeight)
        let outSide = inputSide * scale
        let outMargin = margin * scale
        let planeStride = outSide * outSide
        /// フェザー幅(出力 px)= 前のタイルの延長幅と同じ
        let blend = margin * scale
        // 8bit 量子化では Δ1 階調の段差がフェザー後も 1 本の線として残る。
        // Bayer 8×8 の秩序ディザで丸めを空間分散させて見えなくする
        // (乱数を使わない決定的な処理なので結果は再現可能)
        func component(_ value: Float, _ x: Int, _ y: Int) -> UInt8 {
            let threshold = (Float(bayer8[(y & 7) * 8 + (x & 7)]) + 0.5) / 64
            return UInt8(min(255, max(0, (value * 255 + threshold).rounded(.down))))
        }
        func write(sample: (Int) -> Float) {
            for row in 0..<((contentHeight + extendBottom) * scale) {
                let outY = origin.y * scale + row
                let outRow = outY * bytesPerRow
                let tileRow = (outMargin + row) * outSide
                // 上端のフェザー重み(最初のタイル行では合成相手がないので 1)
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
                        // 既存(左・上のタイルの延長)と新しい値を線形合成
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

    /// Bayer 8×8 行列(値 0-63。秩序ディザのしきい値に使う)
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

    /// タイルの左上座標列(内容領域単位。純関数・テスト対象)
    nonisolated static func tileOrigins(width: Int, height: Int)
        -> [(x: Int, y: Int)] {
        guard width > 0, height > 0 else { return [] }
        var origins: [(x: Int, y: Int)] = []
        for y in stride(from: 0, to: height, by: contentSide) {
            for x in stride(from: 0, to: width, by: contentSide) {
                origins.append((x, y))
            }
        }
        return origins
    }

    // MARK: - ディスクキャッシュ(重い処理の再計算を避ける)

    private nonisolated static var cacheDirectory: URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jp.coo.cooViewer/SuperRes")
    }

    /// キャッシュファイルの場所(キーのハッシュをファイル名にする)
    nonisolated static func cacheFileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(digest + ".heic")
    }

    private static func readDiskCache(for key: String) -> CGImage? {
        let url = cacheFileURL(for: key)
        // 未キャッシュは正常系: 先に存在確認しないと ImageIO が
        // 「can't open (fileExists == false)」をコンソールへ吐いて紛らわしい
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        // 利用のたびに更新日時を進めて、起動時トリムの対象から外す
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: url.path)
        return image
    }

    private static func writeDiskCache(_ image: CGImage, for key: String) {
        try? FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true)
        let url = cacheFileURL(for: key)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            return
        }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.9]
            as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        CGImageDestinationFinalize(destination)
    }

    /// 古い超解像キャッシュの回収(起動時。サムネイルと同じ保持日数)
    nonisolated static func trimDiskCache(olderThanDays days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for child in children {
            let values = try? child.resourceValues(
                forKeys: [.contentModificationDateKey])
            if let date = values?.contentModificationDate, date < cutoff {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }
}
