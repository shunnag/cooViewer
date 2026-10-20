import Foundation

/// 欠落をページとして可視化し、再読込後の着地点も巻のパスで保つ(設計書 §7.4、§2.4)。
struct UnreadableVolumeMarker: Sendable, Hashable {
    let relativePath: String
    /// 未確認の子は原因を断定しない(仕様書 §4.17、設計書 §7.4)。
    let cause: ReadFailureCause?

    var message: String {
        let name = (relativePath as NSString).lastPathComponent
        let reason = cause.map { OpenFailureMessage.causeText($0) }
            ?? String(localized: "This volume could not be checked")
        return name + "\n\n" + reason + "\n\n" + String(localized:
            "This volume could not be read.\nChoose Reload to try again.")
    }
}

/// 本の中の 1 ページ(1 画像)を表す。
struct PageEntry: Sendable, Hashable, Identifiable {
    /// ソース内での安定 ID(書庫エントリ番号 / PDF ページ番号 / フォルダ列挙順)
    let id: Int
    /// 表示名(拡張子付きファイル名)
    let name: String
    /// 本の中の相対パス。ソート(名前順)とサブフォルダ移動の単位に使う。
    /// PDF はページ番号を 0 埋めした擬似パス。
    let pathInBook: String
    /// 実ファイルの URL(フォルダの本のみ。Finder 表示・ゴミ箱に使う)
    let fileURL: URL?
    let creationDate: Date?
    let modificationDate: Date?
    /// コレクション(合本)内のリフロー EPUB の代理ページなら、その EPUB の
    /// URL(表紙 1 ページで本を代表し、表示到達で EPUB モードへ切り替える)。
    /// 常に単独表示(見開きに混ぜない — Book.isSmall が除外する)
    var reflowEPUBURL: URL? = nil
    var unreadableVolume: UnreadableVolumeMarker? = nil

    /// 巻の代理表示を見開きに混ぜると欠落や入場先を見落とす(仕様書 §4.17、設計書 §2.4、§7.4)。
    var isStandalonePage: Bool { reflowEPUBURL != nil || unreadableVolume != nil }

    /// 本の中でこのページが属するフォルダ(サブフォルダ移動の判定単位。仕様書 §4.3.5)
    var containerPath: String {
        (pathInBook as NSString).deletingLastPathComponent
    }

    /// 表示用の名前。relativePath 指定時はサブフォルダ/書庫内の相対パスを含める。
    /// 擬似パスのソース(PDF: 0 埋めページ番号)は末尾がファイル名と一致しないため
    /// 末尾をページ名に置き換える: 最上位 PDF は名前のみ、ネストした PDF は
    /// 「書庫内パス/ページ名」(巻をまたいで同じ「ページ N」にならないように)。
    func displayTitle(relativePath: Bool) -> String {
        guard relativePath, pathInBook != name else { return name }
        if (pathInBook as NSString).lastPathComponent == name { return pathInBook }
        let container = containerPath
        return container.isEmpty ? name : container + "/" + name
    }
}
