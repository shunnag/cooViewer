import Foundation

/// 本の置き場所(ボリューム)の速度特性と、そこから導くキャッシュ/先読みの
/// 方針(設計書「キャッシュ・先読み設計」の自動適応)。
/// 分類は MediaSpeedProbe が行い、本クラスは純粋な「方針表」に徹する。
/// unknown は従来の固定動作と完全に同じ値を返す(判定不能時の回帰防止)。
struct MediaProfile: Sendable, Equatable {
    enum MediaClass: String, Sendable {
        /// 内蔵 SSD・Thunderbolt/USB の SSD 等(実測 ≥ fastThreshold も含む)
        case fastLocal
        /// 回転ディスク(USB-HDD 等)。シークが支配的
        case slowLocal
        /// ネットワークボリューム(SMB/AFP/NFS/WebDAV)。レイテンシが支配的
        case network
        /// 判定できなかった(従来動作を維持)
        case unknown
    }

    var mediaClass: MediaClass
    /// 実測スループット(MB/s)。ベンチを走らせた場合のみ
    var measuredMBPerSec: Double?
    /// スプール方針の明示上書き(設定「高度」の三択)。nil=自動。
    /// 「明示は自動に勝つ」の整合規則(設計書 キャッシュ節)
    var spoolOverride: Bool?

    static let unknown = MediaProfile(mediaClass: .unknown)

    init(mediaClass: MediaClass, measuredMBPerSec: Double? = nil,
         spoolOverride: Bool? = nil) {
        self.mediaClass = mediaClass
        self.measuredMBPerSec = measuredMBPerSec
        self.spoolOverride = spoolOverride
    }

    // MARK: - ベンチマークのしきい値

    /// これ以上は SSD 相当(USB 3 の HDD は実測 ~100-160MB/s 程度、
    /// SATA SSD ~400、NVMe/TB は GB/s 級)
    static let fastThresholdMBPerSec: Double = 180
    /// これ未満は HDD/低速回線相当
    static let slowThresholdMBPerSec: Double = 80

    // MARK: - 方針(設計書のポリシー表)

    /// 書庫をローカル一時展開(スプール)するか。
    /// 高速ローカルではランダムアクセスが安い zip 系のスプールをやめて
    /// 二重書き込みを避ける。solid 圧縮になり得る形式(rar/7z/lha/sit)は
    /// 逐次展開の恩恵が大きいので常にスプールする
    /// independentEntries: 書庫の実構造が「全エントリ独立」(非 solid の 7z/rar 等。
    /// ArchiveSource が solid グループ情報から判定)なら true。構造は拡張子に勝ち、
    /// fastLocal では zip 系と同じくスプールを省いて二重書き込みを避ける
    /// (cooViewer-7ni)。分割ボリュームだけは複数ファイル読みを避けるため常に
    /// スプールする
    func shouldSpoolArchive(fileExtension: String,
                            independentEntries: Bool = false) -> Bool {
        // 高度設定の明示(常に行う/行わない)が最優先
        if let spoolOverride {
            return spoolOverride
        }
        switch mediaClass {
        case .fastLocal:
            let ext = fileExtension.lowercased()
            if SupportedTypes.isSplitVolumeExtension(ext) { return true }
            if independentEntries { return false }
            let solidProne: Set<String> = ["rar", "cbr", "7z", "lha", "lzh", "sit"]
            return solidProne.contains(ext)
        case .slowLocal, .network, .unknown:
            return true
        }
    }

    /// 高速ローカル(SSD)での読み取り/デコード並列度。従来は固定 6 だったが、
    /// Apple Silicon の実効コア数に合わせて引き上げる(高速めくり・サムネイル
    /// 大量読み・深部オープンの立ち上がりで多コアを活かす)。UI・システム用に
    /// 2 コア残し、下限は従来値の 6・上限 12(同時デコードのメモリ膨張を抑える)。
    /// M1(8コア)は 6 のままで回帰なし、Pro/Max ほど広がる。
    static var fastLocalConcurrency: Int {
        min(max(6, ProcessInfo.processInfo.activeProcessorCount - 2), 12)
    }

    /// フォルダの本の同時読み取り上限(サムネイルのセル読みも含む全読者)。
    /// HDD ではシーク嵐を防ぎ、SSD では並列デコードを活かす
    var sourceReadConcurrency: Int {
        switch mediaClass {
        case .fastLocal: Self.fastLocalConcurrency
        case .slowLocal: 2
        case .network: 3
        case .unknown: 64  // 実質無制限(従来動作)
        }
    }

    /// Book 先読みの並列幅(並列ロード可能なソースのみ)。
    /// fastLocal は読み取りゲート(6)と揃え、多コアの並列デコードを活かす
    var bookPrefetchConcurrency: Int {
        switch mediaClass {
        case .fastLocal: Self.fastLocalConcurrency
        case .unknown: 4  // 従来の固定値
        case .slowLocal: 1
        case .network: 2
        }
    }

    /// サムネイル一覧の先読み並列度
    var thumbnailPrefetchConcurrency: Int {
        switch mediaClass {
        case .fastLocal: Self.fastLocalConcurrency
        case .slowLocal, .network: 2
        case .unknown: 3  // 従来の固定値
        }
    }

    /// 先読み深さの既定値(高度設定 OFF のときだけ使う。遅い媒体ほど
    /// レイテンシ隠蔽のため深くする)
    var defaultPrefetchAhead: Int {
        switch mediaClass {
        case .fastLocal, .unknown: SettingsStore.AdvancedDefault.prefetchAhead
        case .slowLocal: 16
        case .network: 20
        }
    }

    var defaultPrefetchBehind: Int {
        switch mediaClass {
        case .fastLocal, .unknown: SettingsStore.AdvancedDefault.prefetchBehind
        case .slowLocal, .network: 4
        }
    }

    // MARK: - 分類(純粋関数。プローブの入力から決める)

    /// プローブが集めた材料からクラスを決める。優先順:
    /// ネットワーク → 物理特性(Medium Type)→ 実測 → unknown
    static func classify(isLocalVolume: Bool,
                         mediumType: MediumType,
                         measuredMBPerSec: Double?) -> MediaProfile {
        if !isLocalVolume {
            return MediaProfile(mediaClass: .network,
                                measuredMBPerSec: measuredMBPerSec)
        }
        switch mediumType {
        case .solidState:
            return MediaProfile(mediaClass: .fastLocal,
                                measuredMBPerSec: measuredMBPerSec)
        case .rotational:
            return MediaProfile(mediaClass: .slowLocal,
                                measuredMBPerSec: measuredMBPerSec)
        case .unknown:
            guard let speed = measuredMBPerSec else {
                return .unknown
            }
            if speed >= fastThresholdMBPerSec {
                return MediaProfile(mediaClass: .fastLocal, measuredMBPerSec: speed)
            }
            if speed < slowThresholdMBPerSec {
                return MediaProfile(mediaClass: .slowLocal, measuredMBPerSec: speed)
            }
            // 中間帯(USB3 HDD の上限〜SATA SSD の下限)は HDD 寄りに倒す:
            // 誤って並列を上げるより、抑える方の誤りが安全
            return MediaProfile(mediaClass: .slowLocal, measuredMBPerSec: speed)
        }
    }

    /// IOKit の Device Characteristics / Medium Type に対応する値
    enum MediumType: Sendable {
        case solidState
        case rotational
        case unknown
    }
}

/// ソースの同時読み取りを絞るゲート(FolderSource 等が全読者に適用する)。
/// 待ち行列は 2 レーン: 表示中ページの読み込み(userInitiated 以上の Task)は
/// 先読みサムネイル生成(utility)の行列を追い越して先に許可される。これがないと
/// 低速媒体でページ表示がサムネイルの後ろに数秒並ばされる。可視セルのサムネイル
/// (urgent)は生成タスクを userInitiated で起動するため、表示中ページと同じ
/// 対話レーンに入り先読みの後ろで飢餓しない(ThumbnailCache 参照)。
/// limit の縮小は実行中の読者には作用しない(次の acquire から効く)
actor SourceReadGate {
    private var limit: Int
    private var active = 0
    private var interactiveWaiters: [CheckedContinuation<Void, Never>] = []
    private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func setLimit(_ newLimit: Int) {
        limit = max(1, newLimit)
        wakeWaitersIfPossible()
    }

    func acquire() async {
        await acquire(interactive: Task.currentPriority >= .userInitiated)
    }

    /// レーン明示版。優先度継承が呼び出し元の意図と一致しない場合
    /// (サムネイルの可視セル要求 vs 先読みの区別など)に使う
    func acquire(interactive: Bool) async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            if interactive {
                interactiveWaiters.append(continuation)
            } else {
                backgroundWaiters.append(continuation)
            }
        }
    }

    func release() {
        active -= 1
        wakeWaitersIfPossible()
    }

    /// 検証用: 現在の使用中/待機数(--dump-thumbnail-stats)
    func debugCounts() -> (active: Int, queued: Int) {
        (active, interactiveWaiters.count + backgroundWaiters.count)
    }

    private func wakeWaitersIfPossible() {
        while active < limit,
              !interactiveWaiters.isEmpty || !backgroundWaiters.isEmpty {
            active += 1
            if !interactiveWaiters.isEmpty {
                interactiveWaiters.removeFirst().resume()
            } else {
                backgroundWaiters.removeFirst().resume()
            }
        }
    }
}
