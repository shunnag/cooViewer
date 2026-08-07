import AppKit

/// ルーペ(仕様書 §4.10 の近代化版)。
/// 旧実装の子ウインドウ(lensWindow)方式は使わず、ReaderView の layer 上に
/// オーバーレイ CALayer を重ねる。ページ layer と同じ CGImage を複製 layer に貼り、
/// 「描画済み内容をマウス位置中心に rate 倍拡大」して見せる方式のため、
/// 全 fitMode・回転・スクロール状態でそのまま動作する。
///
/// 仕様変更: 旧実装の LoupeRate=1.0 は「原寸/表示縮尺のピクセル等倍」だったが
/// (仕様書 §4.10)、新実装の rate は「表示中コンテンツの何倍か」とする
/// (既定 2.0。SettingsStore.loupeRate 参照)。
@MainActor
final class LoupeController {
    struct Page {
        let frame: CGRect
        let image: CGImage
    }

    /// ReaderView の描画状態のスナップショット。
    /// 座標系は ReaderView の layer 座標(container の回転を含む)。
    struct Content {
        var containerBounds: CGRect = .zero
        var containerPosition: CGPoint = .zero
        var containerTransform: CGAffineTransform = .identity
        var pages: [Page] = []
        var backgroundColor: CGColor?
    }

    private let loupeLayer = CALayer()
    private let containerReplica = CALayer()
    private var pageReplicas: [CALayer] = []

    private(set) var isEnabled = false
    private var content = Content()
    private var mousePoint = CGPoint.zero

    /// 正方形の一辺 pt(仕様書 §4.10 LoupeSize)
    var size: CGFloat = 150 {
        didSet { relayout() }
    }

    /// 拡大率(表示中コンテンツ基準。下限 1.0 は呼び出し側で保証)
    var rate: CGFloat = 2 {
        didSet { relayout() }
    }

    init() {
        // 白枠の正方形(仕様書 §4.10)
        loupeLayer.borderColor = CGColor(gray: 1, alpha: 1)
        loupeLayer.borderWidth = 2
        loupeLayer.masksToBounds = true
        loupeLayer.zPosition = 10
        containerReplica.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        loupeLayer.addSublayer(containerReplica)
    }

    // MARK: - 制御

    func enable(in hostLayer: CALayer, at point: CGPoint, content: Content) {
        mousePoint = point
        isEnabled = true
        hostLayer.addSublayer(loupeLayer)
        update(content: content)
    }

    func disable() {
        isEnabled = false
        loupeLayer.removeFromSuperlayer()
    }

    /// マウス移動への追従(仕様書 §4.10: マウス中心)
    func move(to point: CGPoint) {
        mousePoint = point
        relayout()
    }

    /// 描画内容の変化(ページ切替・レイアウト・スクロール)を反映する
    func update(content: Content) {
        self.content = content
        rebuildPageReplicas()
        relayout()
    }

    // MARK: - レイアウト

    private func rebuildPageReplicas() {
        while pageReplicas.count < content.pages.count {
            let layer = CALayer()
            layer.contentsGravity = .resize
            containerReplica.addSublayer(layer)
            pageReplicas.append(layer)
        }
        while pageReplicas.count > content.pages.count {
            pageReplicas.removeLast().removeFromSuperlayer()
        }
    }

    /// マウス位置 p を中心とする拡大写像 q → (q − p)·rate + ルーペ中心 を、
    /// container 複製の位置・変換(回転 × rate 倍)として与える。
    /// ページ layer の複製は container 複製の子なので座標変換はそのまま流用できる。
    private func relayout() {
        guard isEnabled else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        loupeLayer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        loupeLayer.position = mousePoint
        loupeLayer.backgroundColor = content.backgroundColor

        let center = CGPoint(x: size / 2, y: size / 2)
        containerReplica.bounds = content.containerBounds
        containerReplica.position = CGPoint(
            x: (content.containerPosition.x - mousePoint.x) * rate + center.x,
            y: (content.containerPosition.y - mousePoint.y) * rate + center.y)
        containerReplica.setAffineTransform(
            content.containerTransform.scaledBy(x: rate, y: rate))

        for (layer, page) in zip(pageReplicas, content.pages) {
            layer.frame = page.frame
            layer.contents = page.image
        }
    }
}

// MARK: - ReaderWindowController 配線(仕様書 §5.5 action 34/37/38)

extension ReaderWindowController {
    /// ルーペのオン/オフ(仕様書 §4.10)。本が無ければ何もしない。
    func toggleLoupe() {
        guard book != nil else { return }
        let view = readerViewForInput
        if view.isLoupeEnabled {
            view.disableLoupe()
        } else {
            view.enableLoupe(size: settings.loupeSize, rate: settings.loupeRate)
            requestLoupeHighResolution()
        }
    }

    /// 表示中ページのルーペ用高解像度画像を非同期取得して差し込む。
    /// 実効倍率=表示 2 倍 × ルーペ倍率(上限 6 倍)。
    func requestLoupeHighResolution() {
        guard let book, readerViewForInput.isLoupeEnabled else { return }
        let scale = min(6.0, 2.0 * max(1.0, settings.loupeRate))
        Task {
            let spread = await book.currentSpread()
            for (position, index) in spread.indices.enumerated() {
                guard book.entries.indices.contains(index),
                      readerViewForInput.isLoupeEnabled else { return }
                if let image = try? await book.source.loupeImage(
                    for: book.entries[index], pixelScale: scale) {
                    readerViewForInput.setLoupeHighResImage(image, forPageAt: position)
                }
            }
        }
    }

    /// 倍率 ±delta(下限 1.0)。旧実装同様 defaults へ直接保存する(仕様書 §4.10)。
    func adjustLoupeRate(by delta: Double) {
        defer { requestLoupeHighResolution() }
        let rate = max(1.0, settings.loupeRate + delta)
        settings.loupeRate = rate
        readerViewForInput.setLoupeRate(rate)
    }
}
