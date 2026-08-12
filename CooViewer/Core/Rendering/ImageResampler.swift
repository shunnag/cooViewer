import CoreGraphics
import Dispatch
import Foundation

/// 表示ピクセルサイズへの高品質リサンプル(設計書 §5 描画品質)。
/// CALayer の trilinear 拡縮(モアレ・甘さが出る)の代わりに、
/// 縮小は GPU の Lanczos(CG はフォールバック)、拡大は MetalFX Spatial
/// (任意)で事前リサンプルした等倍画像を作る。
/// 結果はバイト基準の LRU に保持する: 現スプレッド+先行リサンプル
/// (最大 5 ページ)+ルーペ超解像が互いに追い出し合わない量を確保しつつ、
/// メモリ圧迫通知で半分に自動トリムする。
actor ImageResampler {
    static let shared = ImageResampler()

    private var cache: [String: CGImage] = [:]
    private var order: [String] = []  // 末尾が最新(MRU)
    private var costs: [String: Int] = [:]
    private var totalCost = 0
    /// 合計バイト上限(既定: 物理メモリの 1/16、最大 512MB)
    private let byteLimit: Int
    private var pressureSource: (any DispatchSourceMemoryPressure)?
    private lazy var metalFX: MetalFXUpscaler? = MetalFXUpscaler()
    private lazy var lanczos: LanczosDownscaler? = LanczosDownscaler()

    init(byteLimit: Int = min(
        512 << 20,
        Int(clamping: ProcessInfo.processInfo.physicalMemory) / 16)) {
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
    /// 同サイズなら image をそのまま返す。upscaleWithMetalFX は拡大時のみ有効で、
    /// 使えない場合は CG へフォールバックする。
    func resample(_ image: CGImage, to pixelSize: CGSize,
                  cacheKey: String, upscaleWithMetalFX: Bool) -> CGImage? {
        let width = Int(pixelSize.width.rounded())
        let height = Int(pixelSize.height.rounded())
        guard width > 0, height > 0 else { return nil }
        if width == image.width, height == image.height { return image }

        let key = "\(cacheKey)|\(image.width)x\(image.height)|\(width)x\(height)|\(upscaleWithMetalFX)"
        if let hit = cache[key] {
            if let index = order.firstIndex(of: key) {
                order.remove(at: index)
                order.append(key)
            }
            return hit
        }

        let isUpscale = width > image.width || height > image.height
        var result: CGImage?
        if isUpscale, upscaleWithMetalFX {
            result = metalFXUpscale(image, width: width, height: height)
        }
        // 縮小は GPU の Lanczos を最優先(CPU の CG 高品質補間はフォールバック)
        if result == nil, !isUpscale {
            result = lanczos?.downscale(image, to: CGSize(width: width, height: height))
        }
        if result == nil {
            result = Self.cgResample(image, width: width, height: height)
        }
        if let result {
            insert(result, for: key)
        }
        return result
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
