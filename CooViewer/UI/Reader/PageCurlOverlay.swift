import QuartzCore

/// ページカールのオーバーレイ構築(ReaderView から使用)。
///
/// 画面をノド(中央)で左右に分割し、空く側の半面を「リーフ」として
/// **帯(横割り)× ストリップ(縦割り)のパッチ格子**で 3D 湾曲させながら
/// 反対側へ倒す。幾何は PageCurlGeometry、面の構成(表=旧内容の空く側、
/// 裏=新内容の着地側)は本物の紙と同じ。
///
/// 実際の本はノドで縫い留められているため、どの帯もノドを起点に連結し、
/// 「下の角が先行する」動きは帯ごとの角の先行(ねじれ)で表現する
/// (リーフ全体を面内回転させるとノドから離れてしまう。過去実装の反省点)。
///
/// アニメーション版(makeAnimated)のほか、任意の進行度で止めた
/// モデル値版(makeStatic)を持ち、CARenderer による実描画テストで
/// 向き・整合・綴じの維持を検証できるようにしている(PageCurlRenderTests)。
@MainActor
enum PageCurlOverlay {
    struct Configuration {
        var bounds: CGRect
        /// リーフ(めくれて空く側)が画面の左半分か
        var leafOnLeft: Bool
        /// めくり開始前の画面内容(表面・着地側の静止表示に使う)
        var oldContent: CGImage
        /// めくり後の画面内容(裏面に使う)
        var newContent: CGImage
        /// 縦割り(カールの丸み)の分割数
        var stripCount = 12
        /// 横割り(ねじれ)の分割数
        var bandCount = 6
        var duration: CFTimeInterval = 0.45
        /// キーフレームの時間分割数
        var timeSteps = 30
    }

    /// 下の角の先行度。下端の帯ほど角を増やす倍率で、ノドは全帯で
    /// 縫い留められたまま下の角から持ち上がる(符号・向きは実描画テストで確認)
    static let cornerLead: CGFloat = 0.5

    // MARK: - 構築

    /// アニメーション付きオーバーレイ。呼び出し側が親レイヤーへ追加し、
    /// duration 経過後に取り除く
    static func makeAnimated(_ config: Configuration) -> CALayer? {
        guard let parts = makeParts(config) else { return nil }
        let timeline = (0...config.timeSteps).map { step in
            frameGeometry(config,
                          progress: CGFloat(step) / CGFloat(config.timeSteps))
        }
        for band in 0..<config.bandCount {
            for strip in 0..<config.stripCount {
                let patch = parts.patches[band][strip]
                let transforms = timeline.map {
                    NSValue(caTransform3D: $0.transforms[band][strip])
                }
                let move = CAKeyframeAnimation(keyPath: "transform")
                move.values = transforms
                move.duration = config.duration
                move.isRemovedOnCompletion = false
                move.fillMode = .forwards

                // 裏面切替(π/2 を跨いだ時刻で内容と切り出し範囲を差し替える)。
                // discrete モードのキータイムは「値の数 + 1」個(区間の境界)
                let crossing = PageCurlGeometry.backfaceKeyTime(
                    angleSamples: timeline.map { $0.angles[band][strip] })
                let swapTimes: [NSNumber] = [0, NSNumber(value: crossing), 1]
                let contentsSwap = CAKeyframeAnimation(keyPath: "contents")
                contentsSwap.values = [config.oldContent, parts.backContent]
                contentsSwap.keyTimes = swapTimes
                contentsSwap.calculationMode = .discrete
                contentsSwap.duration = config.duration
                contentsSwap.isRemovedOnCompletion = false
                contentsSwap.fillMode = .forwards
                let rectSwap = CAKeyframeAnimation(keyPath: "contentsRect")
                rectSwap.values = [
                    NSValue(rect: parts.frontRects[band][strip]),
                    NSValue(rect: parts.backRects[band][strip]),
                ]
                rectSwap.keyTimes = swapTimes
                rectSwap.calculationMode = .discrete
                rectSwap.duration = config.duration
                rectSwap.isRemovedOnCompletion = false
                rectSwap.fillMode = .forwards

                patch.add(move, forKey: "curlMove")
                patch.add(contentsSwap, forKey: "curlContents")
                patch.add(rectSwap, forKey: "curlRect")

                // カールの丸みの陰(角に応じた濃さ)
                let shade = CAKeyframeAnimation(keyPath: "opacity")
                shade.values = timeline.map {
                    NSNumber(value: shadeOpacity(for: $0.angles[band][strip]))
                }
                shade.duration = config.duration
                shade.isRemovedOnCompletion = false
                shade.fillMode = .forwards
                parts.patchShades[band][strip].add(shade, forKey: "curlShade")
            }
        }
        // 着地側の影(前半で濃くなり、リーフが被さって見えなくなる)
        let dim = CAKeyframeAnimation(keyPath: "opacity")
        dim.values = [0, 0.35, 0.35]
        dim.keyTimes = [0, 0.5, 1]
        dim.duration = config.duration
        parts.shadow.add(dim, forKey: "curlShadow")
        return parts.overlay
    }

    /// 進行度 progress(0-1)で止めた静止オーバーレイ(実描画テスト用)
    static func makeStatic(_ config: Configuration, progress: CGFloat) -> CALayer? {
        guard let parts = makeParts(config) else { return nil }
        let frame = frameGeometry(config, progress: progress)
        for band in 0..<config.bandCount {
            for strip in 0..<config.stripCount {
                let patch = parts.patches[band][strip]
                patch.transform = frame.transforms[band][strip]
                if frame.angles[band][strip] >= .pi / 2 {
                    patch.contents = parts.backContent
                    patch.contentsRect = parts.backRects[band][strip]
                }
                parts.patchShades[band][strip].opacity =
                    shadeOpacity(for: frame.angles[band][strip])
            }
        }
        return parts.overlay
    }

    // MARK: - 内部

    /// レイヤー一式(まだ配置は初期状態、アニメーションなし)。
    /// 添字はすべて [帯][ストリップ]
    private struct Parts {
        let overlay: CALayer
        let patches: [[CALayer]]
        /// パッチごとの陰(カールの丸みの表現。角に応じて暗くする)
        let patchShades: [[CALayer]]
        let shadow: CALayer
        let frontRects: [[CGRect]]
        let backRects: [[CGRect]]
        let backContent: CGImage
    }

    /// ある進行度の全パッチ配置(トランスフォームと角。[帯][ストリップ])
    private struct FrameGeometry {
        let transforms: [[CATransform3D]]
        let angles: [[CGFloat]]
    }

    /// ストリップの角 α に応じた陰の濃さ(edge-on で最も暗く、平らで 0)
    private static func shadeOpacity(for angle: CGFloat) -> Float {
        Float(0.30 * sin(angle))
    }

    private static func makeParts(_ config: Configuration) -> Parts? {
        guard config.bounds.width > 1, config.bounds.height > 1,
              config.stripCount > 0, config.bandCount > 0,
              let backContent = mirrored(config.newContent) else { return nil }
        let overlay = CALayer()
        overlay.frame = config.bounds
        overlay.zPosition = 5  // ページの上・ルーペ(10)の下
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 1600
        overlay.sublayerTransform = perspective

        let width = config.bounds.width
        let height = config.bounds.height
        let half = width / 2
        let leafOnLeft = config.leafOnLeft

        // 着地側半面: リーフが被さるまで旧内容が見え続ける
        let landing = CALayer()
        landing.frame = CGRect(x: leafOnLeft ? half : 0, y: 0,
                               width: half, height: height)
        landing.contents = config.oldContent
        landing.contentsRect = CGRect(x: leafOnLeft ? 0.5 : 0, y: 0,
                                      width: 0.5, height: 1)
        overlay.addSublayer(landing)
        let shadow = CALayer()
        shadow.frame = landing.bounds
        shadow.backgroundColor = CGColor(gray: 0, alpha: 1)
        shadow.opacity = 0
        landing.addSublayer(shadow)

        // リーフのパッチ格子。ストリップはノド側から外側の順に重ねる
        // (めくり中は外側ほど手前にあるため)
        var patches: [[CALayer]] = []
        var patchShades: [[CALayer]] = []
        var frontRects: [[CGRect]] = []
        var backRects: [[CGRect]] = []
        let stripLength = half / CGFloat(config.stripCount)
        let bandHeight = height / CGFloat(config.bandCount)
        let xSpan = 0.5 / CGFloat(config.stripCount)
        let ySpan = 1.0 / CGFloat(config.bandCount)
        for band in 0..<config.bandCount {
            var bandPatches: [CALayer] = []
            var bandShades: [CALayer] = []
            var bandFronts: [CGRect] = []
            var bandBacks: [CGRect] = []
            let yOrigin = CGFloat(band) * ySpan
            for stripIndex in 0..<config.stripCount {
                let patch = CALayer()
                // アンカーをノド側の縦エッジに置き、位置は帯の中央高さの
                // 画面中央。配置は transform で与える(キーフレーム/静止値)
                patch.anchorPoint = CGPoint(x: leafOnLeft ? 1 : 0, y: 0.5)
                patch.bounds = CGRect(x: 0, y: 0,
                                      width: stripLength, height: bandHeight)
                patch.position = CGPoint(
                    x: half, y: bandHeight * (CGFloat(band) + 0.5))
                patch.isDoubleSided = true
                patch.edgeAntialiasingMask = []  // 継ぎ目のちらつき抑制
                patch.contents = config.oldContent

                // 表面: 旧内容の「空く側半面」の、この帯・この距離帯の切り出し
                let frontRect = CGRect(
                    x: leafOnLeft ? 0.5 - CGFloat(stripIndex + 1) * xSpan
                                  : 0.5 + CGFloat(stripIndex) * xSpan,
                    y: yOrigin, width: xSpan, height: ySpan)
                // 裏面: 新内容の「着地側半面」の同じ帯・同じ距離帯。
                // 水平鏡像画像から切り出す(裏面描画の反転で正像に戻る)
                let landingRect = CGRect(
                    x: leafOnLeft ? 0.5 + CGFloat(stripIndex) * xSpan
                                  : 0.5 - CGFloat(stripIndex + 1) * xSpan,
                    y: yOrigin, width: xSpan, height: ySpan)
                let backRect = CGRect(x: 1 - landingRect.maxX, y: yOrigin,
                                      width: xSpan, height: ySpan)
                patch.contentsRect = frontRect
                bandFronts.append(frontRect)
                bandBacks.append(backRect)
                // カールの丸みの陰(角に応じて暗くする黒レイヤー)
                let shade = CALayer()
                shade.frame = patch.bounds
                shade.backgroundColor = CGColor(gray: 0, alpha: 1)
                shade.opacity = 0
                patch.addSublayer(shade)
                bandShades.append(shade)
                bandPatches.append(patch)
                overlay.addSublayer(patch)
            }
            patches.append(bandPatches)
            patchShades.append(bandShades)
            frontRects.append(bandFronts)
            backRects.append(bandBacks)
        }
        return Parts(overlay: overlay, patches: patches, patchShades: patchShades,
                     shadow: shadow,
                     frontRects: frontRects, backRects: backRects,
                     backContent: backContent)
    }

    /// 進行度 progress の全パッチ配置。
    /// 帯ごとの先行(lift)で「下の角から」めくれるねじれを作る。
    /// どの帯も連結はノドから始まるため綴じは離れない
    private static func frameGeometry(_ config: Configuration,
                                      progress: CGFloat) -> FrameGeometry {
        let theta = PageCurlGeometry.easedTheta(progress: progress)
        let half = config.bounds.width / 2
        let stripLength = half / CGFloat(config.stripCount)
        let sign: CGFloat = config.leafOnLeft ? -1 : 1
        var transforms: [[CATransform3D]] = []
        var angles: [[CGFloat]] = []
        for band in 0..<config.bandCount {
            // 帯 index は画面の上から下(向きは実描画テストで確認)
            let bottomness = (CGFloat(band) + 0.5) / CGFloat(config.bandCount)
            let placements = PageCurlGeometry.strips(
                theta: theta, lift: cornerLead * bottomness,
                count: config.stripCount, stripLength: stripLength,
                towardRight: !config.leafOnLeft)
            transforms.append(placements.map { placement in
                var transform = CATransform3DMakeTranslation(
                    placement.offsetX, 0, placement.offsetZ)
                transform = CATransform3DRotate(
                    transform, -sign * placement.angle, 0, 1, 0)
                return transform
            })
            angles.append(placements.map(\.angle))
        }
        return FrameGeometry(transforms: transforms, angles: angles)
    }

    /// 水平反転した複製(カール裏面用)。y 軸回転の裏面描画は内容が水平に
    /// 反転して見えるため、あらかじめ反転した複製を渡して正像に戻す
    /// (向きは PageCurlRenderTests の実描画比較で担保)
    private static func mirrored(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: CGFloat(image.width), y: 0)
        context.scaleBy(x: -1, y: 1)
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: image.width, height: image.height))
        return context.makeImage()
    }
}
