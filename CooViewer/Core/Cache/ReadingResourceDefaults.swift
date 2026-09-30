/// 読み込み・キャッシュの標準予算(設計書 §5)。
/// 自動適応・高度設定・本の初期状態が同じ値を使い、保存層には依存しない。
enum ReadingResourceDefaults {
    static let memoryPercent = 15
    static let prefetchAhead = 12
    static let prefetchBehind = 3
    static let displayPixelCap = 4096
    static let spoolLimitGB = 4
    static let prepareNextBookPages = 6
    static let thumbnailCacheDays = 30
}
