import CoreGraphics
import CoreML
import Foundation

/// 圧縮ノイズ低減「強」の実体: waifu2x のノイズ除去モデル(CoreML)。
/// アニメ・マンガ絵の JPEG ノイズ除去に特化した小さな CNN で、
/// CINoiseReduction より大幅に高品質(1 タイル 128×128 を約 2ms で処理)。
///
/// モデル(約 1.2MB)はアプリに同梱せず、「超高」を初回選択して同意した後の
/// **必要時にのみ**本リポジトリのリリース資産(models-1 タグ。外部リポジトリの
/// 構成変更に影響されない自前配信。元は imxieyi/waifu2x-mac、MIT ライセンス。
/// 帰属表示とライセンス全文はリリース側の LICENSES-models.txt)から
/// ダウンロードする(取得・検証・コンパイルは MLModelInstaller が共通処理)。
/// 未導入・失敗時の「超高」は CINoiseReduction(中相当)へフォールバックする
/// (ImageResampler 側)。
actor MLNoiseReducer {
    static let shared = MLNoiseReducer()

    /// 同意ダイアログに表示する概算サイズ
    static let modelSizeDescription = "1.2 MB"

    private let installer = MLModelInstaller(
        specification: .init(
            downloadURL: URL(string:
                "https://github.com/shunnag/cooViewer/releases/download/models-1/anime_noise2_model.mlmodel")!,
            sha256: "bda49fe8993393ae7f90333ce7c92455736c26f740f9d65edf3e1c55494af57f",
            fileName: "anime_noise2_model.mlmodel"),
        status: MLModelInstallStatus.noise)

    // MARK: - waifu2x の入出力仕様

    /// 出力ブロックの一辺(px)
    static let blockSize = 128
    /// 入力に足す文脈マージン(px)。入力の一辺 = blockSize + 2 * shrinkSize
    static let shrinkSize = 7
    /// 入力正規化のオフセット(waifu2x の clip_eta8)
    private static let clipEta8: Float = 0.00196

    // MARK: - 導入

    /// モデルを使える状態にする(必要ならダウンロード→検証→コンパイル→ロード)
    @discardableResult
    func ensureModel() async -> Bool {
        await installer.ensureModel() != nil
    }

    // MARK: - 推論

    /// image のノイズを除去した複製を返す(同サイズ)。
    /// モデル未導入ならバックグラウンドで導入を始め、今回は nil を返す
    /// (呼び出し側は CI フォールバックで表示し、次回から本処理になる)
    func reduce(_ image: CGImage) async -> CGImage? {
        guard let loaded = await installer.ensureModel() else { return nil }
        return Self.runTiled(model: loaded.model, image: image)
    }

    /// タイル推論の本体(モデルへの入出力仕様は probe で実測確認済み:
    /// 入力 "input" 3×142×142、出力 "conv7" [1,1,3,128,128])
    private static func runTiled(model: MLModel, image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let sourceData = { () -> UnsafeMutablePointer<UInt8>? in
                  context.draw(image, in: CGRect(x: 0, y: 0,
                                                 width: width, height: height))
                  return context.data?.assumingMemoryBound(to: UInt8.self)
              }() else { return nil }

        let outBytesPerRow = width * 4
        let outBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: outBytesPerRow * height, alignment: 16)
        let out = outBuffer.assumingMemoryBound(to: UInt8.self)

        let inputSide = blockSize + 2 * shrinkSize
        guard let input = try? MLMultiArray(
            shape: [3, NSNumber(value: inputSide), NSNumber(value: inputSide)],
            dataType: .float32) else {
            outBuffer.deallocate()
            return nil
        }
        let inputPointer = input.dataPointer.assumingMemoryBound(to: Float.self)
        let planeStride = inputSide * inputSide

        for origin in tileOrigins(width: width, height: height) {
            if Task.isCancelled {
                outBuffer.deallocate()
                return nil
            }
            // 入力: タイル(+マージン)を画像から集める。画像端は端画素を複製
            for row in 0..<inputSide {
                let sourceY = min(max(origin.y + row - shrinkSize, 0), height - 1)
                for column in 0..<inputSide {
                    let sourceX = min(max(origin.x + column - shrinkSize, 0),
                                      width - 1)
                    let pixel = sourceY * outBytesPerRow + sourceX * 4
                    let position = row * inputSide + column
                    inputPointer[position] =
                        Float(sourceData[pixel]) / 255 + clipEta8
                    inputPointer[planeStride + position] =
                        Float(sourceData[pixel + 1]) / 255 + clipEta8
                    inputPointer[planeStride * 2 + position] =
                        Float(sourceData[pixel + 2]) / 255 + clipEta8
                }
            }
            guard let provider = try? MLDictionaryFeatureProvider(
                    dictionary: ["input": MLFeatureValue(multiArray: input)]),
                  let prediction = try? model.prediction(from: provider),
                  let result = prediction.featureValue(for: "conv7")?
                      .multiArrayValue else {
                outBuffer.deallocate()
                return nil
            }
            writeTile(result, into: out, bytesPerRow: outBytesPerRow,
                      origin: origin, width: width, height: height)
        }

        guard let provider = CGDataProvider(
            dataInfo: nil, data: outBuffer,
            size: outBytesPerRow * height,
            releaseData: { _, data, _ in data.deallocate() }) else {
            outBuffer.deallocate()
            return nil
        }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: outBytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent)
    }

    /// 出力タイル([1,1,3,128,128]。Float32/Double 両対応)を出力バッファへ書く
    private static func writeTile(_ result: MLMultiArray,
                                  into out: UnsafeMutablePointer<UInt8>,
                                  bytesPerRow: Int, origin: (x: Int, y: Int),
                                  width: Int, height: Int) {
        let tileWidth = min(blockSize, width - origin.x)
        let tileHeight = min(blockSize, height - origin.y)
        let planeStride = blockSize * blockSize
        func component(_ value: Float) -> UInt8 {
            UInt8(min(255, max(0, (value * 255).rounded())))
        }
        func write(sample: (Int) -> Float) {
            for row in 0..<tileHeight {
                let outRow = (origin.y + row) * bytesPerRow
                for column in 0..<tileWidth {
                    let position = row * blockSize + column
                    let pixel = outRow + (origin.x + column) * 4
                    out[pixel] = component(sample(position))
                    out[pixel + 1] = component(sample(planeStride + position))
                    out[pixel + 2] = component(sample(planeStride * 2 + position))
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

    /// タイルの左上座標列(出力ブロック単位。純関数・テスト対象)
    nonisolated static func tileOrigins(width: Int, height: Int)
        -> [(x: Int, y: Int)] {
        guard width > 0, height > 0 else { return [] }
        var origins: [(x: Int, y: Int)] = []
        for y in stride(from: 0, to: height, by: blockSize) {
            for x in stride(from: 0, to: width, by: blockSize) {
                origins.append((x, y))
            }
        }
        return origins
    }
}
