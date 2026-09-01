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
    /// 進行中の計算(key → タスク)。同一キーの並行 resample を1本の計算へ
    /// 合流させ、ML/CI の二重実行を避ける(preresample と表示要求が同じページを
    /// 同時に要求する経路。cooViewer-pag)。id は完了時の自己退去照合用
    /// (ThumbnailCache.inFlight と同型)
    private var inFlight: [String: (task: Task<CGImage?, Never>, id: UUID)] = [:]
    /// 検証用: 実計算(computeResample)に入った回数。合流が効けば同一キーの
    /// 並行要求で 1 回になる(stats().computeCount で参照)
    private var computeCount = 0
    /// 検証用: reducedSource(ノイズ低減の実計算)に入った回数。.strong の中間
    /// 結果キャッシュが効けば、同一元画像を別 target で複数回リサンプルしても
    /// 1 回になる(cooViewer-kli)
    private var reducedSourceCount = 0
    /// ML 恒久失敗中に ML 系キーへ焼いた CI フォールバックのキー(最終・中間とも)。
    /// モデルが .ready へ回復したら removeMLFallbackEntries で捨て、本物の ML で
    /// 作り直させる(cooViewer-emx)。追い出し時は removeEntry が同期して外す
    private var mlFallbackKeys: Set<String> = []
    /// 合計バイト上限(既定: 物理メモリの 1/5、最大 12GB)。
    /// リサンプル済み(高品質化・ML 超解像)画像は再計算が高価なため、
    /// 行き来で作り直さずに済むよう広めに確保する(旧: 1/6・最大 4.5GB は
    /// アクティビティ窓でデコードキャッシュ 16GB に比べ使用率が高く、
    /// 大容量メモリ機でキャップが早く効いていた)。メモリ圧時は trimToHalf が
    /// 半減させる安全弁があるため、先読み予算(1/8・最大 4GB)+表示・ルーペ分に
    /// 余裕を持たせても実使用は圧に応じて縮む
    private let byteLimit: Int
    private var pressureSource: (any DispatchSourceMemoryPressure)?
    private lazy var metalFX: MetalFXUpscaler? = MetalFXUpscaler()
    private lazy var lanczos: LanczosDownscaler? = LanczosDownscaler()
    private lazy var noiseReducer: NoiseReducer? = NoiseReducer()

    /// アクティビティ窓向けの読み取り専用スナップショット(O(1))
    struct Stats: Sendable, Equatable {
        let count: Int
        let usedBytes: Int
        let limitBytes: Int
        let computeCount: Int
        let reducedSourceCount: Int
    }
    func stats() -> Stats {
        Stats(count: cache.count, usedBytes: totalCost, limitBytes: byteLimit,
              computeCount: computeCount, reducedSourceCount: reducedSourceCount)
    }

    init(byteLimit: Int = min(
        12 << 30,
        Int(clamping: ProcessInfo.processInfo.physicalMemory) / 5)) {
        self.byteLimit = max(1, byteLimit)
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility))
        self.pressureSource = source
        // @Sendable でクロージャの隔離推論を止める(ReaderView のメモリ圧ハンドラ参照:
        // 非 Sendable な setEventHandler に actor 隔離のクロージャを渡すと utility キューでの
        // 発火時に隔離アサートで SIGTRAP する。macOS 26.6 のクラッシュ)。
        source.setEventHandler { @Sendable [weak self] in
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
        // 同一キーの計算が進行中なら合流する(ML/CI の二重実行を避ける。
        // preresample と表示要求が同じページを同時に要求する経路。cooViewer-pag)。
        // touch ミス・in-flight 照合・タスク生成・登録は最初の中断より前の同期
        // アクター操作なので、再入で重複タスクが割り込むことはない
        if let running = inFlight[key] {
            let joined = await running.task.value
            // 合流待ち手のキャンセルは結果を捨てるだけ(insert は計算タスクの
            // 責務)。共有タスクは待ち手のキャンセルを観測しないので結果は本物
            return Task.isCancelled ? nil : joined
        }
        let id = UUID()
        let task = Task { [weak self] () -> CGImage? in
            guard let self else { return nil }
            return await self.computeResample(
                image: image, width: width, height: height, key: key,
                cacheKey: cacheKey, upscaleWithMetalFX: upscaleWithMetalFX,
                noiseReduction: noiseReduction, superResEncrypted: superResEncrypted)
        }
        inFlight[key] = (task, id)
        // Task.value は Never 失敗タスクではキャンセル点にならず、待ち手が
        // キャンセルされても計算は完走してから戻る(結果は常に本物・キャッシュ可)。
        // 完了後に自己退去(id 照合で新しい世代を潰さない)
        let result = await task.value
        if inFlight[key]?.id == id { inFlight[key] = nil }
        return Task.isCancelled ? nil : result
    }

    /// リサンプル本体(ノイズ低減 + リサイズ + キャッシュ)。in-flight の共有
    /// タスクから同一キーにつき1回だけ呼ばれる。共有タスクは待ち手のキャンセルを
    /// 観測しないため結果は常に完走した本物で、旧来の「キャンセル結果を ML 用
    /// キーに焼かない」汚染ガードは合流により構造的に不要になった(cooViewer-pag)
    private func computeResample(
        image: CGImage, width: Int, height: Int, key: String,
        cacheKey: String, upscaleWithMetalFX: Bool,
        noiseReduction: NoiseReductionLevel, superResEncrypted: Bool
    ) async -> CGImage? {
        computeCount += 1
        // .strong のノイズ低減(waifu2x)中間結果は元画像サイズ依存で target 非依存。
        // 結果キャッシュは target 込みキーなので、ウインドウリサイズ(別 target)ごとに
        // フル CNN を再実行していた(cooViewer-kli)。中間結果を元サイズキーで
        // キャッシュし、リサイズ間で再利用する(.maximum は SR ディスク層が担う)
        let nrKey: String? = noiseReduction == .strong
            ? "\(cacheKey)|\(image.width)x\(image.height)|nr-strong" : nil
        let source: CGImage
        let usedMLFallback: Bool
        if let nrKey, let cached = cache[nrKey] {
            source = cached
            usedMLFallback = false  // キャッシュ済み=下でキャッシュ可否を通した本物
            touch(nrKey)
        } else {
            reducedSourceCount += 1
            // 圧縮ノイズ低減(JPEG のブロックノイズ)。最高・強は CoreML モデル、
            // 弱/中(およびモデル未導入時のフォールバック)は CINoiseReduction
            (source, usedMLFallback) = await reducedSource(
                of: image, level: noiseReduction, cacheKey: cacheKey,
                encrypted: superResEncrypted)
            // 中間結果のキャッシュ可否は最終結果と同じ 7n1.2 規則。恒久失敗機
            // (.failed/XCTest)は CI 中間も焼いてリサイズ再計算を防ぐ、一過性
            // フォールバック(未導入/DL 中)はモデル完成後の本物に譲るため焼かない
            if let nrKey,
               await resolvedCacheable(usedMLFallback: usedMLFallback,
                                       image: image, level: noiseReduction) {
                insert(source, for: nrKey)
                if usedMLFallback { mlFallbackKeys.insert(nrKey) }  // 回復時に捨てる(emx)
            }
        }
        // モデル推論の await 中に別経路が同じキーを入れていたら使い回す
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
        if let result,
           await resolvedCacheable(usedMLFallback: usedMLFallback,
                                   image: image, level: noiseReduction) {
            insert(result, for: key)
            if usedMLFallback { mlFallbackKeys.insert(key) }  // 回復時に捨てる(emx)
        }
        return result
    }

    /// ML モデルが .ready へ回復したときに呼ぶ(MLModelInstaller から)。恒久失敗中に
    /// ML 系キーへ焼いた CI フォールバックを捨て、次回要求で本物の ML により作り直す
    /// (cooViewer-emx。7n1.2 のトレードオフの隙間 = 一時失敗→回復で CI が残る問題)
    func removeMLFallbackEntries() {
        let keys = mlFallbackKeys
        mlFallbackKeys.removeAll()
        for key in keys { removeEntry(key) }
    }

    /// ML 一過性フォールバック(モデル未導入/DL 中)は ML 用キーに焼き付けない
    /// — モデル完成後に再計算させる(cooViewer-2za item5)。ただし ML が恒久失敗
    /// (.failed)した機では毎表示 CI 再計算になるため、恒久失敗なら焼き付けを許可
    /// する(cooViewer-7n1.2)。XCTest は ML 即 failed で決定的に許可
    /// (testResamplerCachesSeparatelyPerReductionLevel の === 判定を保つため)。
    /// 最終結果と .strong 中間結果で共通の判定(cooViewer-kli で切り出し)
    private func resolvedCacheable(usedMLFallback: Bool, image: CGImage,
                                   level: NoiseReductionLevel) async -> Bool {
        let retryPossible: Bool
        if !usedMLFallback {
            retryPossible = true
        } else if AutomatedRun.isXCTest {
            retryPossible = false
        } else {
            let srApplicable = max(image.width, image.height)
                <= MLSuperResolver.maxSourceEdge
            retryPossible = await Self.mlRetryPossible(
                for: level, superResApplicable: srApplicable)
        }
        return Self.cachesFallback(
            usedMLFallback: usedMLFallback, mlRetryPossible: retryPossible)
    }

    /// ML 階層を要求したが一過性に CI へ落ちた結果をキャッシュしてよいか。
    /// mlRetryPossible な間はキャッシュせず(完成後に再計算)、恒久不可なら許可する
    static func cachesFallback(usedMLFallback: Bool, mlRetryPossible: Bool) -> Bool {
        !(usedMLFallback && mlRetryPossible)
    }

    /// ML 恒久失敗(.failed)なら再試行不可 → キャッシュ許可。未導入/DL 中は再試行の
    /// 見込みがあるので焼き付けない。@MainActor の導入状態をアクタ境界越しに 1 回だけ
    /// 読み、比較結果の Bool だけを持ち帰る(State 型をアクタ境界に跨がせない)。
    /// 最高は超解像・ノイズの双方が「再試行不可」になって初めて false(=キャッシュ許可)。
    /// ただし超解像は元画像が大きすぎると(maxSourceEdge 超)モデル .ready でも常に nil を
    /// 返すので、その画像では超解像を「再試行可能」に数えない(毎表示再計算の再発防止)。
    static func mlRetryPossible(for level: NoiseReductionLevel,
                                superResApplicable: Bool) async -> Bool {
        await MainActor.run {
            switch level {
            case .maximum:
                return (superResApplicable
                        && MLModelInstallStatus.superResolution.state != .failed)
                    || MLModelInstallStatus.noise.state != .failed
            default:
                return MLModelInstallStatus.noise.state != .failed
            }
        }
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
        // このメソッドは共有キーでキャッシュしないため fallback フラグは無視
        await reducedSource(of: image, level: level.cappedForOriginalSize,
                            cacheKey: nil).image
    }

    /// ノイズ低減の実処理の振り分け。
    /// 最高 = Real-ESRGAN ×4 超解像(結果は 4 倍サイズ。後段の縮小で画質向上)、
    /// 強 = waifu2x ノイズ除去。ML 系は未導入・失敗・画像過大で 1 段ずつ
    /// フォールバックする(最高→強→中相当の CI)。
    /// usedMLFallback = ML 階層(.strong/.maximum)を要求したが ML 経路が nil で
    /// CI 近似に落ちたか(呼び出し側がキャッシュ可否を判断する。.weak/.medium は
    /// CI が本来の結果なので false)
    private func reducedSource(of image: CGImage,
                               level: NoiseReductionLevel,
                               cacheKey: String?,
                               encrypted: Bool = false)
        async -> (image: CGImage, usedMLFallback: Bool) {
        guard level != .none else { return (image, false) }
        if level == .maximum {
            // ディスクキャッシュのキーは元画像サイズまで含めて一意にする
            let srKey = cacheKey.map { "\($0)|\(image.width)x\(image.height)|sr4" }
            if let upscaled = await MLSuperResolver.shared.upscale(
                image, cacheKey: srKey, encrypted: encrypted) {
                return (upscaled, false)
            }
        }
        if level == .strong || level == .maximum,
           let reduced = await MLNoiseReducer.shared.reduce(image) {
            return (reduced, false)
        }
        let requestedML = level == .strong || level == .maximum
        return (noiseReducer?.reduce(image, level: level) ?? image, requestedML)
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
        mlFallbackKeys.remove(key)  // 追い出したキーは回復対象から外す(emx)
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
