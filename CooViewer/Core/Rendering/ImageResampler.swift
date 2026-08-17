import CoreGraphics
import Dispatch
import Foundation

/// 表示ピクセルサイズへの高品質リサンプル(設計書 §5 描画品質)。
/// CALayer の trilinear 拡縮(モアレ・甘さが出る)の代わりに、
/// 縮小は GPU の Lanczos(CG はフォールバック)、拡大は MetalFX Spatial
/// (任意)で事前リサンプルした等倍画像を作る。
/// 結果はバイト基準の LRU に保持する: 現スプレッド+先行リサンプル
/// (PreresamplePolicy の予算・最大 4GB)+ルーペ超解像が互いに
/// 追い出し合わない量を確保しつつ、メモリ圧迫通知で半分に自動トリムする。
actor ImageResampler {
    static let shared = ImageResampler()

    private var cache: [String: CGImage] = [:]
    private var order: [String] = []  // 末尾が最新(MRU)
    private var costs: [String: Int] = [:]
    private var totalCost = 0
    /// 合計バイト上限(既定: 物理メモリの 1/6、最大 4.5GB。
    /// 先読み予算(1/8・最大 4GB)+表示中スプレッド・ルーペ分の余裕)
    private let byteLimit: Int
    private var pressureSource: (any DispatchSourceMemoryPressure)?
    private lazy var metalFX: MetalFXUpscaler? = MetalFXUpscaler()
    private lazy var lanczos: LanczosDownscaler? = LanczosDownscaler()
    private lazy var noiseReducer: NoiseReducer? = NoiseReducer()

    init(byteLimit: Int = min(
        4608 << 20,
        Int(clamping: ProcessInfo.processInfo.physicalMemory) / 6)) {
        self.byteLimit = max(1, byteLimit)
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility))
        self.pressureSource = source
        source.setEventHandler { [weak self] in
            Task { await self?.trimToHalf() }
        }
        source.activate()
    }

    deinit {
        pressureSource?.cancel()
    }

    /// image を pixelSize(デバイスピクセル)へリサンプルする。
    /// 同サイズ(かつノイズ低減なし)なら image をそのまま返す。
    /// upscaleWithMetalFX は拡大時のみ有効で、使えない場合は CG へ
    /// フォールバックする。noiseReduction を指定するとリサンプルの前に
    /// 圧縮ノイズ低減を掛ける(拡大時にノイズを増幅させないため前段で行う)
    func resample(_ image: CGImage, to pixelSize: CGSize,
                  cacheKey: String, upscaleWithMetalFX: Bool,
                  noiseReduction: NoiseReductionLevel = .none,
                  superResEncrypted: Bool = false) async -> CGImage? {
        let width = Int(pixelSize.width.rounded())
        let height = Int(pixelSize.height.rounded())
        guard width > 0, height > 0 else { return nil }
        if width == image.width, height == image.height,
           noiseReduction == .none { return image }

        let key = Self.makeKey(cacheKey: cacheKey, image: image,
                               width: width, height: height,
                               upscaleWithMetalFX: upscaleWithMetalFX,
                               noiseReduction: noiseReduction)
        if let hit = touch(key) { return hit }

        // 圧縮ノイズ低減(JPEG のブロックノイズ)。最高・強は CoreML モデル、
        // 弱/中(およびモデル未導入時のフォールバック)は CINoiseReduction
        let source = await reducedSource(of: image, level: noiseReduction,
                                         cacheKey: cacheKey,
                                         encrypted: superResEncrypted)
        // キャンセルされた呼び出しの結果は捨てる: ML がキャンセルで nil を
        // 返すと source は CI フォールバックの絵になっており、これを
        // キャッシュすると ML 用キーに非 ML の結果が残る(先読みの
        // 表示優先キャンセルで顕在化する汚染の防止)
        if Task.isCancelled { return nil }
        // モデル推論の await 中に同じキーの計算が完了していたら使い回す
        if let hit = cache[key] { return hit }

        let isUpscale = width > source.width || height > source.height
        var result: CGImage?
        if width == source.width, height == source.height {
            result = source  // ノイズ低減のみ(サイズ変更なし)
        }
        if result == nil, isUpscale, upscaleWithMetalFX {
            result = metalFXUpscale(source, width: width, height: height)
        }
        // 縮小は GPU の Lanczos を最優先(CPU の CG 高品質補間はフォールバック)
        if result == nil, !isUpscale {
            result = lanczos?.downscale(source, to: CGSize(width: width, height: height))
        }
        if result == nil {
            result = Self.cgResample(source, width: width, height: height)
        }
        if let result {
            insert(result, for: key)
        }
        return result
    }

    /// リサンプル済みキャッシュの照会のみ(計算はしない。命中は MRU 更新)。
    /// ページめくり効果の最初のフレームから完成画像を使うための引き当てで、
    /// resample と同じ引数から同じキーを組み立てる
    func cached(_ image: CGImage, to pixelSize: CGSize,
                cacheKey: String, upscaleWithMetalFX: Bool,
                noiseReduction: NoiseReductionLevel = .none) -> CGImage? {
        let width = Int(pixelSize.width.rounded())
        let height = Int(pixelSize.height.rounded())
        guard width > 0, height > 0 else { return nil }
        return touch(Self.makeKey(cacheKey: cacheKey, image: image,
                                  width: width, height: height,
                                  upscaleWithMetalFX: upscaleWithMetalFX,
                                  noiseReduction: noiseReduction))
    }

    /// キャッシュキー(resample / cached で共通)
    private static func makeKey(cacheKey: String, image: CGImage,
                                width: Int, height: Int,
                                upscaleWithMetalFX: Bool,
                                noiseReduction: NoiseReductionLevel) -> String {
        "\(cacheKey)|\(image.width)x\(image.height)|\(width)x\(height)"
            + "|\(upscaleWithMetalFX)|nr\(noiseReduction.rawValue)"
    }

    /// 命中エントリを MRU に上げて返す
    private func touch(_ key: String) -> CGImage? {
        guard let hit = cache[key] else { return nil }
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        return hit
    }

    /// リサイズを伴わない圧縮ノイズ低減(ルーペ・原寸表示用)。
    /// なし指定・失敗時はそのまま返す。「最高」は縮小表示前の ×4 拡大が
    /// 前提の仕組みのため、等倍系のこの経路では「強」として扱う
    func reduceNoise(_ image: CGImage, level: NoiseReductionLevel) async -> CGImage {
        await reducedSource(of: image, level: level.cappedForOriginalSize,
                            cacheKey: nil)
    }

    /// ノイズ低減の実処理の振り分け。
    /// 最高 = Real-ESRGAN ×4 超解像(結果は 4 倍サイズ。後段の縮小で画質向上)、
    /// 強 = waifu2x ノイズ除去。ML 系は未導入・失敗・画像過大で 1 段ずつ
    /// フォールバックする(最高→強→中相当の CI)
    private func reducedSource(of image: CGImage,
                               level: NoiseReductionLevel,
                               cacheKey: String?,
                               encrypted: Bool = false) async -> CGImage {
        guard level != .none else { return image }
        if level == .maximum {
            // ディスクキャッシュのキーは元画像サイズまで含めて一意にする
            let srKey = cacheKey.map { "\($0)|\(image.width)x\(image.height)|sr4" }
            if let upscaled = await MLSuperResolver.shared.upscale(
                image, cacheKey: srKey, encrypted: encrypted) {
                return upscaled
            }
        }
        if level == .strong || level == .maximum,
           let reduced = await MLNoiseReducer.shared.reduce(image) {
            return reduced
        }
        return noiseReducer?.reduce(image, level: level) ?? image
    }

    // MARK: - バイト基準 LRU(PageCache と同じ方針)

    private func insert(_ image: CGImage, for key: String) {
        removeEntry(key)
        let cost = image.bytesPerRow * image.height
        cache[key] = image
        costs[key] = cost
        totalCost += cost
        order.append(key)
        // 上限超過分を古い順に破棄。1 枚だけで超過する場合はその 1 枚は保持
        // (再リサンプルの繰り返しを防ぐ)
        while totalCost > byteLimit, order.count > 1 {
            removeEntry(order[0])
        }
    }

    private func removeEntry(_ key: String) {
        guard cache[key] != nil else { return }
        cache.removeValue(forKey: key)
        totalCost -= costs.removeValue(forKey: key) ?? 0
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
    }

    /// メモリ圧迫時: 使用量を半分まで削る
    func trimToHalf() {
        let target = totalCost / 2
        while totalCost > target, order.count > 1 {
            removeEntry(order[0])
        }
    }

    /// MetalFX による拡大(2 倍超の段階適用は MetalFXUpscaler 内でテクスチャの
    /// まま行われる)。失敗時は nil を返し、呼び出し元が CG へフォールバック。
    private func metalFXUpscale(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        metalFX?.upscale(image, to: CGSize(width: width, height: height))
    }

    /// CG の高品質補間(Lanczos 相当)によるリサンプル
    static func cgResample(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        // グレースケール/CMYK は RGBA コンテキストを作れないため sRGB へ変換する
        let sourceSpace = image.colorSpace
        let space = (sourceSpace?.model == .rgb ? sourceSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
