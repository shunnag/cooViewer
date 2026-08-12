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
/// 影は**パッチに載せず**、幾何(ロールの頂点位置)に追従する単一レイヤー群で
/// 描く: 投影影(ロール直下の柔らかい影)・接触影(その芯)・綴じ目の陰影・
/// 紙の縁ハイライト・着地側の影。パッチ毎に陰レイヤーを重ねる方式は、
/// ヘアライン対策の重なり部分で二重に暗くなり格子(四角)が見えるため廃止
/// (過去実装の反省点)。
///
/// アニメーション版(makeAnimated)のほか、任意の進行度で止めた
/// モデル値版(makeStatic)を持ち、CARenderer による実描画テストで
/// 向き・整合・綴じ・シームの有無を検証できるようにしている
/// (PageCurlRenderTests)。
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
        /// 横割り(ねじれ)の分割数。ねじれによる帯間の食い違いは
        /// 1 帯あたり数 pt 以下に収まるよう細かめにする
        var bandCount = 24
        var duration: CFTimeInterval = 0.45
        /// キーフレームの時間分割数(120Hz 表示でも補間段差が出ない密度)
        var timeSteps = 48
    }

    /// 下の角の先行度。下端の帯ほど角を増やす倍率で、ノドは全帯で
    /// 縫い留められたまま下の角から持ち上がる(符号・向きは実描画テストで確認)
    static let cornerLead: CGFloat = 0.35

    /// ねじれのフェードアウト境界。角を掴む感じが要るのは序盤だけなので、
    /// θ がここへ近づくにつれ帯間の角度差を二乗カーブで 0 に戻す
    /// (中盤以降の帯間の食い違い=階段状の隙間・横線ノイズを消す)
    static let leadFadeEndTheta: CGFloat = 0.6 * .pi

    /// パッチの重なり(pt)。丸めやアンチエイリアスで帯・ストリップ境界に
    /// 出るヘアライン(横線/縦線)を隠す
    static let patchOverlap: CGFloat = 1.2

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
            }
        }

        // 幾何追従の影(位置=ロール頂点の投影 x、濃さ=めくりの進み)
        let gutterX = config.bounds.width / 2
        func addTrack(_ layer: CALayer, keyPath: String, values: [NSNumber]) {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.duration = config.duration
            animation.isRemovedOnCompletion = false
            animation.fillMode = .forwards
            layer.add(animation, forKey: "curl-\(keyPath)")
        }
        addTrack(parts.castShadow, keyPath: "position.x",
                 values: timeline.map { NSNumber(value: gutterX + $0.apexX) })
        addTrack(parts.castShadow, keyPath: "opacity",
                 values: timeline.map { NSNumber(value: 0.30 * $0.thetaSin) })
        addTrack(parts.contactShadow, keyPath: "position.x",
                 values: timeline.map { NSNumber(value: gutterX + $0.apexX) })
        addTrack(parts.contactShadow, keyPath: "opacity",
                 values: timeline.map { NSNumber(value: 0.30 * $0.thetaSin) })
        addTrack(parts.gutterShade, keyPath: "opacity",
                 values: timeline.map { NSNumber(value: 0.35 * $0.thetaSin) })
        for highlight in parts.edgeHighlights {
            addTrack(highlight, keyPath: "opacity",
                     values: timeline.map { NSNumber(value: 0.45 * $0.outerSin) })
        }
        // 着地側の影(前半で濃くなり、リーフが被さって見えなくなる)
        let dim = CAKeyframeAnimation(keyPath: "opacity")
        dim.values = [0, 0.30, 0.30]
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
            }
        }
        let gutterX = config.bounds.width / 2
        parts.castShadow.position.x = gutterX + frame.apexX
        parts.castShadow.opacity = Float(0.30 * frame.thetaSin)
        parts.contactShadow.position.x = gutterX + frame.apexX
        parts.contactShadow.opacity = Float(0.30 * frame.thetaSin)
        parts.gutterShade.opacity = Float(0.35 * frame.thetaSin)
        for highlight in parts.edgeHighlights {
            highlight.opacity = Float(0.45 * frame.outerSin)
        }
        return parts.overlay
    }

    // MARK: - 内部

    /// レイヤー一式(まだ配置は初期状態、アニメーションなし)。
    /// patches 等の添字は [帯][ストリップ]
    private struct Parts {
        let overlay: CALayer
        let patches: [[CALayer]]
        /// 着地側の影(リーフ接近で暗くなる)
        let shadow: CALayer
        /// 投影影(ロール直下の広く柔らかい影。下の live 内容にも落ちる)
        let castShadow: CALayer
        /// 接触影(投影影の芯。紙が面に近い所の濃く狭い影)
        let contactShadow: CALayer
        /// 綴じ目(ノド)の陰影
        let gutterShade: CALayer
        /// 紙の縁のハイライト(自由端。帯ごとに外側パッチへ内蔵)
        let edgeHighlights: [CALayer]
        let frontRects: [[CGRect]]
        let backRects: [[CGRect]]
        let backContent: CGImage
    }

    /// ある進行度の全パッチ配置と影の材料。
    /// apexX はロール頂点(α≈π/2)のノド基準投影 x(符号付き)
    private struct FrameGeometry {
        let transforms: [[CATransform3D]]
        let angles: [[CGFloat]]
        let apexX: CGFloat
        let thetaSin: CGFloat
        let outerSin: CGFloat
    }

    /// 単位矩形(0-1)へのクランプ(境界の重なりぶんのはみ出しを丸める)
    private static func clampedUnitRect(_ rect: CGRect) -> CGRect {
        let minX = max(0, rect.minX)
        let minY = max(0, rect.minY)
        return CGRect(x: minX, y: minY,
                      width: min(1, rect.maxX) - minX,
                      height: min(1, rect.maxY) - minY)
    }

    /// 縦ストライプの影(中央が濃く左右へ透ける水平グラデーション)
    private static func makeVerticalShadow(coreAlpha: CGFloat, width: CGFloat,
                                           height: CGFloat) -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.startPoint = CGPoint(x: 0, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.colors = [
            CGColor(gray: 0, alpha: 0),
            CGColor(gray: 0, alpha: coreAlpha),
            CGColor(gray: 0, alpha: 0),
        ]
        layer.locations = [0, 0.5, 1]
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        layer.opacity = 0
        return layer
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

        // 投影影と接触影(リーフの下に敷く: パッチより先に追加)。
        // 位置はロール頂点へキーフレームで追従する
        let castShadow = makeVerticalShadow(coreAlpha: 1,
                                            width: half * 0.55, height: height)
        castShadow.position = CGPoint(x: half, y: height / 2)
        overlay.addSublayer(castShadow)
        let contactShadow = makeVerticalShadow(coreAlpha: 1,
                                               width: half * 0.14, height: height)
        contactShadow.position = CGPoint(x: half, y: height / 2)
        overlay.addSublayer(contactShadow)

        // リーフのパッチ格子。ストリップはノド側から外側の順に重ねる
        // (めくり中は外側ほど手前にあるため)
        var patches: [[CALayer]] = []
        var edgeHighlights: [CALayer] = []
        var frontRects: [[CGRect]] = []
        var backRects: [[CGRect]] = []
        let stripLength = half / CGFloat(config.stripCount)
        let bandHeight = height / CGFloat(config.bandCount)
        let xSpan = 0.5 / CGFloat(config.stripCount)
        let ySpan = 1.0 / CGFloat(config.bandCount)
        // 境界のヘアライン対策: パッチを外側+上下に patchOverlap ぶん広げ、
        // 切り出し範囲も同じだけ広げる(後着のレイヤーが上に重なり隙間が消える)
        let xPad = patchOverlap / width
        let yPad = patchOverlap / height
        for band in 0..<config.bandCount {
            var bandPatches: [CALayer] = []
            var bandFronts: [CGRect] = []
            var bandBacks: [CGRect] = []
            let yOrigin = CGFloat(band) * ySpan
            for stripIndex in 0..<config.stripCount {
                let patch = CALayer()
                // アンカーをノド側の縦エッジに置き、位置は帯の中央高さの
                // 画面中央。配置は transform で与える(キーフレーム/静止値)
                patch.anchorPoint = CGPoint(x: leafOnLeft ? 1 : 0, y: 0.5)
                patch.bounds = CGRect(
                    x: 0, y: 0,
                    width: stripLength + patchOverlap,
                    height: bandHeight + patchOverlap)
                patch.position = CGPoint(
                    x: half, y: bandHeight * (CGFloat(band) + 0.5))
                patch.isDoubleSided = true
                patch.edgeAntialiasingMask = []  // 継ぎ目のちらつき抑制
                patch.contents = config.oldContent

                // 表面: 旧内容の「空く側半面」の、この帯・この距離帯の切り出し
                let frontRect = clampedUnitRect(CGRect(
                    x: leafOnLeft
                        ? 0.5 - CGFloat(stripIndex + 1) * xSpan - xPad
                        : 0.5 + CGFloat(stripIndex) * xSpan,
                    y: yOrigin - yPad / 2,
                    width: xSpan + xPad, height: ySpan + yPad))
                // 裏面: 新内容の「着地側半面」の同じ帯・同じ距離帯。
                // 水平鏡像画像から切り出す(裏面描画の反転で正像に戻る)
                let landingRect = CGRect(
                    x: leafOnLeft
                        ? 0.5 + CGFloat(stripIndex) * xSpan
                        : 0.5 - CGFloat(stripIndex + 1) * xSpan - xPad,
                    y: yOrigin - yPad / 2,
                    width: xSpan + xPad, height: ySpan + yPad)
                let backRect = clampedUnitRect(
                    CGRect(x: 1 - landingRect.maxX, y: landingRect.minY,
                           width: landingRect.width, height: landingRect.height))
                patch.contentsRect = frontRect
                bandFronts.append(frontRect)
                bandBacks.append(backRect)

                // 紙の縁のハイライト(最外ストリップの自由端に細い明線。
                // パッチ内蔵なので湾曲・ねじれにそのまま追従する)
                if stripIndex == config.stripCount - 1 {
                    let highlight = CALayer()
                    let lineWidth: CGFloat = 1.5
                    highlight.frame = CGRect(
                        x: leafOnLeft ? 0 : patch.bounds.width - lineWidth,
                        y: 0, width: lineWidth, height: patch.bounds.height)
                    highlight.backgroundColor = CGColor(gray: 1, alpha: 1)
                    highlight.opacity = 0
                    patch.addSublayer(highlight)
                    edgeHighlights.append(highlight)
                }
                bandPatches.append(patch)
                overlay.addSublayer(patch)
            }
            patches.append(bandPatches)
            frontRects.append(bandFronts)
            backRects.append(bandBacks)
        }

        // 綴じ目(ノド)の陰影(最前面。低い不透明度で両半面の谷を示す)
        let gutterShade = makeVerticalShadow(coreAlpha: 1,
                                             width: width * 0.07, height: height)
        gutterShade.position = CGPoint(x: half, y: height / 2)
        overlay.addSublayer(gutterShade)

        return Parts(overlay: overlay, patches: patches, shadow: shadow,
                     castShadow: castShadow, contactShadow: contactShadow,
                     gutterShade: gutterShade, edgeHighlights: edgeHighlights,
                     frontRects: frontRects, backRects: backRects,
                     backContent: backContent)
    }

    /// 進行度 progress の全パッチ配置と影の材料。
    /// 帯ごとの先行(lift)で「下の角から」めくれるねじれを作る。
    /// どの帯も連結はノドから始まるため綴じは離れない
    private static func frameGeometry(_ config: Configuration,
                                      progress: CGFloat) -> FrameGeometry {
        let theta = PageCurlGeometry.easedTheta(progress: progress)
        let half = config.bounds.width / 2
        let stripLength = half / CGFloat(config.stripCount)
        let sign: CGFloat = config.leafOnLeft ? -1 : 1
        // ねじれは序盤に集中させ、中盤で 0 に戻す(帯間の食い違い防止)
        let fade = max(0, 1 - theta / leadFadeEndTheta)
        let leadNow = cornerLead * fade * fade
        var transforms: [[CATransform3D]] = []
        var angles: [[CGFloat]] = []
        for band in 0..<config.bandCount {
            // 帯 index は画面の上から下(向きは実描画テストで確認)
            let bottomness = (CGFloat(band) + 0.5) / CGFloat(config.bandCount)
            let placements = PageCurlGeometry.strips(
                theta: theta, lift: leadNow * bottomness,
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
        // 影の材料は帯中央相当の基準配置から取る(帯に依存させない)
        let reference = PageCurlGeometry.strips(
            theta: theta, lift: leadNow * 0.5,
            count: config.stripCount, stripLength: stripLength,
            towardRight: !config.leafOnLeft)
        // ロール頂点 = α が π/2 に最も近いストリップの投影 x
        var apexX: CGFloat = 0
        var bestDelta = CGFloat.greatestFiniteMagnitude
        for placement in reference {
            let delta = abs(placement.angle - .pi / 2)
            if delta < bestDelta {
                bestDelta = delta
                apexX = placement.offsetX
            }
        }
        let outerAngle = reference.last?.angle ?? 0
        return FrameGeometry(transforms: transforms, angles: angles,
                             apexX: apexX,
                             thetaSin: sin(theta),
                             outerSin: sin(outerAngle))
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
