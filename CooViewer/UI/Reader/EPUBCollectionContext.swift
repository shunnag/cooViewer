import Foundation

/// コレクション(合本)内から開いた EPUB の文脈。
/// 巻端・次/前の本で合本の隣接エントリへ復帰し、キー/マウスの綴じ方向解決
/// (readsFromLeft)は本の宣言ではなく**コレクションの readMode** に従う
/// (表示は宣言どおり — 混在方向のコレクションで操作系が本ごとに
/// 反転しないようにする。設計書 §2.4 EPUB 対応)
struct EPUBCollectionContext {
    /// 合本(コレクションフォルダ)の URL(復帰先・兄弟走査の基準)
    let folderURL: URL
    /// 合本内での代理ページの位置(復帰は前後の隣接エントリへ)
    let entryIndex: Int
    /// 合本の総エントリ数(巻端判定用)
    let entryCount: Int
    /// コレクションの readMode 由来の操作系綴じ方向
    let readsFromLeft: Bool
    /// 合本のエントリ列とソース(EPUB 内からもコレクション全体の
    /// サムネイル一覧を出すために持ち回る。ソースは参照なので軽い)
    let entries: [PageEntry]
    let source: any BookSource
    /// 一覧の見開きペア判定用(合本の設定を引き継ぐ)
    let singleSetting: Int
    let coverSingle: Bool
    /// しおり付きページ(合本の実ページ index)
    let bookmarkedPages: Set<Int>
}
