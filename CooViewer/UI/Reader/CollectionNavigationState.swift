import Foundation

/// 合本の画像ページとリフロー EPUB を往来する状態。個別 EPUB の終了をまたいで
/// 持ち回るためウインドウが所有する。失敗マーカーの寿命を読書セッションに合わせない。
@MainActor
final class CollectionNavigationState {
    var arrivalForward: Bool?
    var arrivalAtFirst = false
    /// 復帰オープンが進行している間だけ true。openGeneration を照合する入口の
    /// defer が解除し、巻端のキーリピートによる二重復帰を防ぐ。
    var returnPending = false
    private var permanentFailures: Set<URL> = []
    /// 一過性の失敗は今回の代理表紙へ着地するための消費式マーカー。
    /// 一括クリアは設けない。挿入→合本復帰→着地→消費の順序を守らないと、
    /// 壊れた巻の自動入場と合本復帰が循環する。
    private var transientFailures: Set<URL> = []

    func takeArrival() -> (forward: Bool?, atFirst: Bool) {
        let arrival = (arrivalForward, arrivalAtFirst)
        arrivalForward = nil
        arrivalAtFirst = false
        return arrival
    }

    func hasPermanentFailure(for url: URL) -> Bool {
        permanentFailures.contains(url)
    }

    /// 確定した FXL/DRM 降格。初回だけ理由を知らせるため、初回登録かを返す。
    @discardableResult
    func recordPermanentFailure(for url: URL) -> Bool {
        permanentFailures.insert(url).inserted
    }

    func recordTransientFailure(for url: URL) {
        transientFailures.insert(url)
    }

    /// 自動入場を判断する直前だけ呼ぶ。true なら今回は表紙を表示し、次の
    /// 意図的な再着地では解析を再試行できる。
    func consumeTransientFailure(for url: URL) -> Bool {
        transientFailures.remove(url) != nil
    }
}
