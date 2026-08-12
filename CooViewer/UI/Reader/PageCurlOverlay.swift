import QuartzCore

/// ページカールのオーバーレイ構築(ReaderView から使用)。
///
/// 画面をノド(中央)で左右に分割し、空く側の半面を「リーフ」として
/// ストリップ列で 3D 湾曲させながら反対側へ倒す。幾何は PageCurlGeometry、
/// 面の構成(表=旧内容の空く側、裏=新内容の着地側)は本物の紙と同じ。
/// アニメーション版(makeAnimated)のほか、任意の進行度で止めた
/// モデル値版(makeStatic)を持ち、CARenderer による実描画テストで
/// 向き・整合を検証できるようにしている(PageCurlRenderTests)。
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
        var stripCount = 12
        var duration: CFTimeInterval = 0.45
        /// キーフレームの時間分割数
        var timeSteps = 30
    }

    /// めくり途中の傾き(下の角が先に持ち上がる)の最大角。
    /// sin(θ) 比例で効かせるため、始端・終端では 0 に戻り正確に整合する
    static let maxTilt: CGFloat = 0.22

    // MARK: - 構築

    /// アニメーション付きオーバーレイ。呼び出し側が親レイヤーへ追加し、
    /// duration 経過後に取り除く
    static func makeAnimated(_ config: Configuration) -> CALayer? {
        guard let parts = makeParts(config) else { return nil }
        let timeline = (0...config.timeSteps).map { step in
            frameGeometry(config,
                          progress: CGFloat(step) / CGFloat(config.timeSteps))
        }
        for (index, strip) in parts.strips.enumerated() {
            let transforms = timeline.map {
                NSValue(caTransform3D: $0.transforms[index])
            }
            let move = CAKeyframeAnimation(keyPath: "transform")
            move.values = transforms
            move.duration = config.duration
            move.isRemovedOnCompletion = false
            move.fillMode = .forwards

            // 裏面切替(π/2 を跨いだ時刻で内容と切り出し範囲を差し替える)。
            // discrete モードのキータイムは「値の数 + 1」個(区間の境界)
            let crossing = PageCurlGeometry.backfaceKeyTime(
                angleSamples: timeline.map { $0.angles[index] })
            let swapTimes: [NSNumber] = [0, NSNumber(value: crossing), 1]
            let contentsSwap = CAKeyframeAnimation(keyPath: "contents")
            contentsSwap.values = [config.oldContent, parts.backContent]
            contentsSwap.keyTimes = swapTimes
            contentsSwap.calculationMode = .discrete
            contentsSwap.duration = config.duration
            contentsSwap.isRemovedOnCompletion = false
            contentsSwap.fillMode = .forwards
            let rectSwap = CAKeyframeAnimation(keyPath: "contentsRect")
            rectSwap.values = [NSValue(rect: parts.frontRects[index]),
                               NSValue(rect: parts.backRects[index])]
            rectSwap.keyTimes = swapTimes
            rectSwap.calculationMode = .discrete
            rectSwap.duration = config.duration
            rectSwap.isRemovedOnCompletion = false
            rectSwap.fillMode = .forwards

            strip.add(move, forKey: "curlMove")
            strip.add(contentsSwap, forKey: "curlContents")
            strip.add(rectSwap, forKey: "curlRect")
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
        for (index, strip) in parts.strips.enumerated() {
            strip.transform = frame.transforms[index]
            if frame.angles[index] >= .pi / 2 {
                strip.contents = parts.backContent
                strip.contentsRect = parts.backRects[index]
            }
        }
        return parts.overlay
    }

    // MARK: - 内部

    /// レイヤー一式(まだ配置は初期状態、アニメーションなし)
    private struct Parts {
        let overlay: CALayer
        let strips: [CALayer]
        let shadow: CALayer
        let frontRects: [CGRect]
        let backRects: [CGRect]
        let backContent: CGImage
    }

    /// ある進行度のストリップ配置(トランスフォームと角)
    private struct FrameGeometry {
        let transforms: [CATransform3D]
        let angles: [CGFloat]
    }

    private static func makeParts(_ config: Configuration) -> Parts? {
        guard config.bounds.width > 1, config.bounds.height > 1,
              config.stripCount > 0,
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

        // リーフのストリップ列(ノド側から外側の順。外側ほど手前に重なる)
        var strips: [CALayer] = []
        var frontRects: [CGRect] = []
        var backRects: [CGRect] = []
        let stripLength = half / CGFloat(config.stripCount)
        let span = 0.5 / CGFloat(config.stripCount)
        for stripIndex in 0..<config.stripCount {
            let strip = CALayer()
            // アンカーをノド側の縦エッジに置き、位置は常に画面中央。
            // 配置はすべて transform で与える(キーフレーム/静止値)
            strip.anchorPoint = CGPoint(x: leafOnLeft ? 1 : 0, y: 0.5)
            strip.bounds = CGRect(x: 0, y: 0, width: stripLength, height: height)
            strip.position = CGPoint(x: half, y: height / 2)
            strip.isDoubleSided = true
            strip.edgeAntialiasingMask = []  // 継ぎ目のちらつき抑制
            strip.contents = config.oldContent

            // 表面: 旧内容の「空く側半面」をノドからの距離で輪切りにする
            let frontRect = CGRect(
                x: leafOnLeft ? 0.5 - CGFloat(stripIndex + 1) * span
                              : 0.5 + CGFloat(stripIndex) * span,
                y: 0, width: span, height: 1)
            // 裏面: 新内容の「着地側半面」の同じ距離帯。180° 回転画像から
            // 切り出す(裏面描画の反転で正像に戻る)。y は回転で上下も
            // 入れ替わるため全高のまま(rect の y 反転は 0..1 全域では不変)
            let landingRect = CGRect(
                x: leafOnLeft ? 0.5 + CGFloat(stripIndex) * span
                              : 0.5 - CGFloat(stripIndex + 1) * span,
                y: 0, width: span, height: 1)
            let backRect = CGRect(x: 1 - landingRect.maxX, y: 0,
                                  width: span, height: 1)
            strip.contentsRect = frontRect
            frontRects.append(frontRect)
            backRects.append(backRect)
            strips.append(strip)
            overlay.addSublayer(strip)
        }
        return Parts(overlay: overlay, strips: strips, shadow: shadow,
                     frontRects: frontRects, backRects: backRects,
                     backContent: backContent)
    }

    /// 進行度 progress の全ストリップ配置。
    /// 傾き(下の角が先行)は sin(θ) 比例で、ノドの下端を支点に画面内で
    /// リーフ全体を回す(始端・終端では 0 に戻るため整合が崩れない)
    private static func frameGeometry(_ config: Configuration,
                                      progress: CGFloat) -> FrameGeometry {
        let theta = PageCurlGeometry.easedTheta(progress: progress)
        let half = config.bounds.width / 2
        let height = config.bounds.height
        let stripLength = half / CGFloat(config.stripCount)
        let sign: CGFloat = config.leafOnLeft ? -1 : 1
        let placements = PageCurlGeometry.strips(
            theta: theta, count: config.stripCount,
            stripLength: stripLength, towardRight: !config.leafOnLeft)
        // 支点と符号は実描画テスト(下の帯が先に空く)で確認したもの
        let tilt = sign * maxTilt * sin(theta)
        let transforms = placements.map { placement -> CATransform3D in
            // ノド下端を支点にした面内の傾き → ノド基準の連結配置 → 自身の傾き
            var transform = CATransform3DMakeTranslation(0, -height / 2, 0)
            transform = CATransform3DRotate(transform, tilt, 0, 0, 1)
            transform = CATransform3DTranslate(transform, 0, height / 2, 0)
            transform = CATransform3DTranslate(
                transform, placement.offsetX, 0, placement.offsetZ)
            transform = CATransform3DRotate(
                transform, -sign * placement.angle, 0, 1, 0)
            return transform
        }
        return FrameGeometry(transforms: transforms,
                             angles: placements.map(\.angle))
    }

    /// 180° 回転した複製(カール裏面用)。
    /// 幾何(y 軸回転)の水平反転に加え、実際の描画環境では裏面の内容が
    /// 垂直にも反転して表示される(CARenderer による実描画テストで確認。
    /// PageCurlRenderTests)ため、両軸を反転した複製を渡して正像に戻す
    private static func mirrored(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: CGFloat(image.width), y: CGFloat(image.height))
        context.scaleBy(x: -1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: image.width, height: image.height))
        return context.makeImage()
    }
}
