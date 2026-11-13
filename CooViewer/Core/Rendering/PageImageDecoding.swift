import CoreGraphics
import Foundation
import PrintAppearanceKit

/// 本のページ画像のデコードの入口(設計書 §5)。フォルダ・書庫(2 か所)・EPUB の単一画像ページが
/// ここを通る。網点処理の要求(PageRequestIntent.printAppearance)がなければ、従来どおり先読みのゲートの
/// 中で ImageDecoding.decode を呼ぶだけで、結果も従来と同じ。
///
/// 要求があるとき:
///   1. ゲートの中(同期の葉。従来のデコードと同じ扱い)で PrintAppearance.prepare を呼ぶ。素通しのページは
///      ここで網点処理を切ったときと同じ画素を作って返す。
///   2. ゲートを出てから PrintAppearanceService でエンジンに処理させる。エンジンの待ちの間ゲートの枠を
///      持たない(枠はデコードの葉だけを覆う。持つと別の本やカラーページの先読みまでエンジンの速さに縛られる)。
///   3. PrintAppearance.recolour で完成画像にする。変えるのは明るさだけで、ファイルの色は保つ:
///      1 チャンネルのグレーのソースは 8 bit の Generic Gray 2.2(1 画素 1 バイト)、RGB のソースは
///      sRGB の描き直しに輝度の差を足した RGB(1 画素 4 バイト。切ったときの RGB のファイルと同じ大きさ)。
///      RGB のソースのページは sRGB の描き直し(1 画素 4 バイト)を持ってエンジンを待ち、ここで手放す。
///   4. 上限(maxPixelSize)を超えるページは原寸で処理・仕上げしてから縮める。処理は原寸のラスタの網点の
///      周期を見るので、縮めてから処理しない。
///
/// 未処理の画素を返すのは決定的な素通し(prepare の判定と、CPU の経路でも断られたページ)だけ。
/// GPU の失敗・作業域の不足・取り消し・間引き・辞退は例外のまま返す(キャッシュのタグの下に未処理の画素を
/// 入れないため。超解像のディスクキャッシュのキーにもタグが入る)。
enum PageImageDecoding {
    /// service はテスト用の差し替え。nil なら要求があるときだけ共有のサービスを使う
    /// (要求のない従来の経路ではサービスに触れず、何も作らない)
    static func decode(_ data: Data, maxPixelSize: Int?,
                       service: PrintAppearanceService? = nil) async throws -> CGImage {
        // 上限が 0 以下の要求は従来の経路で同じ例外にする
        if let request = PageRequestIntent.printAppearance, (maxPixelSize ?? 1) > 0 {
            return try await decode(data, maxPixelSize: maxPixelSize, request: request,
                                    service: service ?? .shared)
        }
        return try await PrefetchDecodeGate.run {
            try ImageDecoding.decode(data, maxPixelSize: maxPixelSize,
                                    displayTarget: PageRequestIntent.displayColorTarget)
        }
    }

    private enum Prepared: Sendable {
        case unchanged(CGImage, PrintAppearancePassReason)
        case ready(PrintAppearancePage)
    }

    private enum Processed: Sendable {
        /// 網点処理を切ったときと同じ画素(決定的な素通し)
        case unchanged(CGImage)
        /// 原寸の完成画像
        case finished(PrintAppearanceOutput)
    }

    private static func decode(_ data: Data, maxPixelSize: Int?, request: PrintAppearanceRequest,
                               service: PrintAppearanceService) async throws -> CGImage {
        switch try await process(data, maxPixelSize: maxPixelSize, request: request, service: service) {
        case .unchanged(let image):
            return image
        case .finished(let output):
            return try finishedImage(output, maxPixelSize: maxPixelSize)
        }
    }

    /// prepare からエンジンと仕上げまで。ページ(RGB のソースは描き直しを含む)はこの中だけで持ち、
    /// 縮小と画像化の前に手放す
    private static func process(_ data: Data, maxPixelSize: Int?, request: PrintAppearanceRequest,
                                service: PrintAppearanceService) async throws -> Processed {
        let maxPixels = service.maxPixels
        // prepare が投げるのは作業域を確保できないときだけ。素通しにはせず、読み込みの失敗にする
        let prepared = try await PrefetchDecodeGate.run { () throws -> Prepared in
            switch try PrintAppearance.prepare(data, maxPixels: maxPixels) {
            case .passThrough(let reason, let raw):
                return .unchanged(try unchangedImage(data, maxPixelSize: maxPixelSize, raw: raw), reason)
            case .ready(let page):
                return .ready(page)
            }
        }
        let page: PrintAppearancePage
        switch prepared {
        case .unchanged(let image, let reason):
            service.recordPassThrough(reason)
            return .unchanged(image)
        case .ready(let ready):
            page = ready
        }
        let gray: PrintAppearanceGray
        do {
            gray = try await service.process(page, request: request)
        } catch PrintAppearanceError.unsupportedPage {
            // CPU の厳密な経路でも断られたページ(同じ入力なら常に断られる)は決定的な素通し: 切ったときと同じ画素
            return .unchanged(try await PrefetchDecodeGate.run {
                try ImageDecoding.decode(data, maxPixelSize: maxPixelSize,
                                        displayTarget: PageRequestIntent.displayColorTarget)
            })
        }
        return .finished(try PrintAppearance.recolour(page, processed: gray))
    }

    /// 素通しのページは網点処理を切ったときと同じ画素にする。上限なしの要求で prepare がデコードを済ませて
    /// いればそれを使う: ImageDecoding の上限なしの経路も、何も問い合わせていないソースから同じ呼び出しで
    /// デコードするため。上限ありの経路はデコードの前にヘッダを読み、JPEG によってはそれでデコード結果が
    /// 変わるので、ImageDecoding.decode をもう一度呼ぶ(上限ありの素通しはデコードが 2 回になる)
    private static func unchangedImage(_ data: Data, maxPixelSize: Int?, raw: CGImage?) throws -> CGImage {
        let displayTarget = PageRequestIntent.displayColorTarget
        if maxPixelSize == nil, let raw { return displayTarget?.converted(raw) ?? raw }
        return try ImageDecoding.decode(data, maxPixelSize: maxPixelSize, displayTarget: displayTarget)
    }

    /// 完成画像を上限へ縮め(長辺を上限に固定する従来の寸法の規則。RGB も同じ高品質の再標本化)、画像にする。
    /// Generic Gray 2.2 は表示先の灰色と同じ空間なので、グレーは表示先の変換で通常そのまま返る。
    /// sRGB の RGB は切ったときの RGB のページと同じく表示先の空間へ変換する
    private static func finishedImage(_ output: PrintAppearanceOutput, maxPixelSize: Int?) throws -> CGImage {
        var page = output
        if let cap = maxPixelSize, max(output.width, output.height) > cap {
            guard let size = ImageDecoding.cappedDimensions(width: output.width, height: output.height, cap: cap)
            else {
                throw BookSourceError.pageLoadFailed("invalid pixel cap")
            }
            if size.width != output.width || size.height != output.height {
                page = try PrintAppearance.reduce(output, width: size.width, height: size.height)
            }
        }
        guard let image = page.makeImage() else {
            throw BookSourceError.pageLoadFailed("print appearance image")
        }
        return PageRequestIntent.displayColorTarget?.converted(image) ?? image
    }
}
