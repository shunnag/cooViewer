import CoreGraphics
import CoreML
import CryptoKit
import Foundation

/// 超解像モデルの導入状態(設定 UI が表示するためのブリッジ)。
/// 実体は MLNoiseReducer(actor)が更新する
@MainActor
final class MLNoiseReducerStatus: ObservableObject {
    static let shared = MLNoiseReducerStatus()

    enum State {
        case notInstalled
        case downloading
        case ready
        case failed
    }

    @Published var state: State = .notInstalled
}

/// 圧縮ノイズ低減「強」の実体: waifu2x のノイズ除去モデル(CoreML)。
/// アニメ・マンガ絵の JPEG ノイズ除去に特化した小さな CNN で、
/// CINoiseReduction より大幅に高品質(1 タイル 128×128 を約 2ms で処理)。
///
/// モデル(約 1.2MB)はアプリに同梱せず、「強」を初回選択して同意した後の
/// **必要時にのみ**配布元(imxieyi/waifu2x-mac、MIT ライセンス)から
/// ダウンロードする。SHA-256 をピン留めして検証し、Application Support に
/// 保存・コンパイルして使い回す。未導入・失敗時の「強」は CINoiseReduction
/// (中相当)へフォールバックする(ImageResampler 側)。
actor MLNoiseReducer {
    static let shared = MLNoiseReducer()

    // MARK: - モデル配布元(バージョンと SHA-256 をピン留め)

    private static let modelDownloadURL = URL(string:
        "https://raw.githubusercontent.com/imxieyi/waifu2x-mac/master/waifu2x-mac/models/anime_noise2_model.mlmodel")!
    private static let modelSHA256 =
        "bda49fe8993393ae7f90333ce7c92455736c26f740f9d65edf3e1c55494af57f"
    /// 同意ダイアログに表示する概算サイズ
    static let modelSizeDescription = "1.2 MB"

    // MARK: - waifu2x の入出力仕様

    /// 出力ブロックの一辺(px)
    static let blockSize = 128
    /// 入力に足す文脈マージン(px)。入力の一辺 = blockSize + 2 * shrinkSize
    static let shrinkSize = 7
    /// 入力正規化のオフセット(waifu2x の clip_eta8)
    private static let clipEta8: Float = 0.00196

    // MARK: - 状態

    private var model: MLModel?
    private var installing = false

    private var modelDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jp.coo.cooViewer/Models")
    }

    private var modelFileURL: URL {
        modelDirectory.appendingPathComponent("anime_noise2_model.mlmodel")
    }

    private var compiledURL: URL {
        modelDirectory.appendingPathComponent("anime_noise2_model.mlmodelc")
    }

    private func setStatus(_ state: MLNoiseReducerStatus.State) {
        Task { @MainActor in
            MLNoiseReducerStatus.shared.state = state
        }
    }

    // MARK: - 導入

    /// モデルを使える状態にする(必要ならダウンロード→検証→コンパイル→ロード)。
    /// XCTest 実行ではネットワークに触れない方針のため常に失敗扱い
    @discardableResult
    func ensureModel() async -> Bool {
        if model != nil { return true }
        guard !installing else { return false }
        guard !AutomatedRun.isXCTest else {
            setStatus(.failed)
            return false
        }
        installing = true
        defer { installing = false }

        let fileManager = FileManager.default
        do {
            // 1. ダウンロード(既存の検証済みファイルがあれば再利用)
            if !fileManager.fileExists(atPath: modelFileURL.path)
                || !verifyModelHash() {
                setStatus(.downloading)
                let (data, _) = try await URLSession.shared.data(
                    from: Self.modelDownloadURL)
                let digest = SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }.joined()
                guard digest == Self.modelSHA256 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try fileManager.createDirectory(
                    at: modelDirectory, withIntermediateDirectories: true)
                try data.write(to: modelFileURL, options: .atomic)
                try? fileManager.removeItem(at: compiledURL)  // 再コンパイルさせる
            }
            // 2. コンパイル(結果はキャッシュして使い回す)
            if !fileManager.fileExists(atPath: compiledURL.path) {
                let compiled = try await MLModel.compileModel(at: modelFileURL)
                try? fileManager.removeItem(at: compiledURL)
                try fileManager.moveItem(at: compiled, to: compiledURL)
            }
            // 3. ロード(Neural Engine を含む全ユニットを許可)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            model = try MLModel(contentsOf: compiledURL,
                                configuration: configuration)
            setStatus(.ready)
            return true
        } catch {
            setStatus(.failed)
            return false
        }
    }

    private func verifyModelHash() -> Bool {
        guard let data = try? Data(contentsOf: modelFileURL) else { return false }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        return digest == Self.modelSHA256
    }

    /// 起動済みセッションでの状態問い合わせ(設定画面の表示更新用)
    func refreshStatus() {
        if model != nil {
            setStatus(.ready)
        } else if FileManager.default.fileExists(atPath: modelFileURL.path) {
            setStatus(.notInstalled)  // 未ロード(次の使用時にロードされる)
        } else {
            setStatus(.notInstalled)
        }
    }

    // MARK: - 推論

    /// image のノイズを除去した複製を返す(同サイズ)。
    /// モデル未導入ならバックグラウンドで導入を始め、今回は nil を返す
    /// (呼び出し側は CI フォールバックで表示し、次回から本処理になる)
    func reduce(_ image: CGImage) async -> CGImage? {
        if model == nil {
            let ready = await ensureModel()
            guard ready else { return nil }
        }
        guard let model else { return nil }
        return Self.runTiled(model: model, image: image)
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
