import Foundation

/// 本の置き場所(ボリューム)の速度特性と、そこから導くキャッシュ/先読みの
/// 方針(設計書「キャッシュ・先読み設計」の自動適応)。
/// 分類は MediaSpeedProbe が行い、本クラスは純粋な「方針表」に徹する。
/// unknown は従来の固定動作と完全に同じ値を返す(判定不能時の回帰防止)。
/// EN: Speed class of the volume a book lives on, plus the derived cache and
/// EN: prefetch policy. Classification lives in MediaSpeedProbe; this type is
/// EN: a pure policy table. `.unknown` reproduces the legacy fixed behavior.
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
    /// EN: Measured throughput when the micro-benchmark ran.
    var measuredMBPerSec: Double?
    /// スプール方針の明示上書き(設定「高度」の三択)。nil=自動。
    /// 「明示は自動に勝つ」の整合規則(設計書 キャッシュ節)
    /// EN: Explicit spool-policy override from Advanced settings; nil = auto.
    /// EN: Explicit values always beat the automatic policy.
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
    /// EN: At or above this the volume behaves like an SSD.
    static let fastThresholdMBPerSec: Double = 180
    /// これ未満は HDD/低速回線相当
    /// EN: Below this it behaves like a spinning disk or slow link.
    static let slowThresholdMBPerSec: Double = 80

    // MARK: - 方針(設計書のポリシー表)

    /// 書庫をローカル一時展開(スプール)するか。
    /// 高速ローカルではランダムアクセスが安い zip 系のスプールをやめて
    /// 二重書き込みを避ける。solid 圧縮になり得る形式(rar/7z/lha/sit)は
    /// 逐次展開の恩恵が大きいので常にスプールする
    /// EN: Whether to spool an archive: fast local volumes skip zip-style
    /// EN: formats (cheap random access); solid-prone formats always spool.
    func shouldSpoolArchive(fileExtension: String) -> Bool {
        // 高度設定の明示(常に行う/行わない)が最優先
        // EN: An explicit Advanced-tab policy always wins.
        if let spoolOverride {
            return spoolOverride
        }
        switch mediaClass {
        case .fastLocal:
            let solidProne: Set<String> = ["rar", "cbr", "7z", "lha", "lzh", "sit"]
            return solidProne.contains(fileExtension.lowercased())
                || SupportedTypes.isSplitVolumeExtension(fileExtension.lowercased())
        case .slowLocal, .network, .unknown:
            return true
        }
    }

    /// フォルダの本の同時読み取り上限(サムネイルのセル読みも含む全読者)。
    /// HDD ではシーク嵐を防ぎ、SSD では並列デコードを活かす
    /// EN: Concurrent-read cap for folder books (all readers, thumbnails too).
    var sourceReadConcurrency: Int {
        switch mediaClass {
        case .fastLocal: 6
        case .slowLocal: 2
        case .network: 3
        case .unknown: 64  // 実質無制限(従来動作)
        }
    }

    /// Book 先読みの並列幅(並列ロード可能なソースのみ)。
    /// fastLocal は読み取りゲート(6)と揃え、多コアの並列デコードを活かす
    /// EN: Prefetch width used by Book for parallel-capable sources;
    /// EN: fastLocal matches the read gate so decodes pipeline fully.
    var bookPrefetchConcurrency: Int {
        switch mediaClass {
        case .fastLocal: 6
        case .unknown: 4  // 従来の固定値
        case .slowLocal: 1
        case .network: 2
        }
    }

    /// サムネイル一覧の先読み並列度
    /// EN: Thumbnail-overlay prefetch concurrency.
    var thumbnailPrefetchConcurrency: Int {
        switch mediaClass {
        case .fastLocal: 6
        case .slowLocal, .network: 2
        case .unknown: 3  // 従来の固定値
        }
    }

    /// 先読み深さの既定値(高度設定 OFF のときだけ使う。遅い媒体ほど
    /// レイテンシ隠蔽のため深くする)
    /// EN: Default prefetch depth (used only while Advanced settings are off).
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
    /// EN: Pure classification: network, then medium type, then benchmark.
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
            // EN: The ambiguous band leans slow — over-parallelizing a disk
            // EN: hurts more than under-parallelizing an SSD.
            return MediaProfile(mediaClass: .slowLocal, measuredMBPerSec: speed)
        }
    }

    /// IOKit の Device Characteristics / Medium Type に対応する値
    /// EN: Mirrors IOKit's medium-type device characteristic.
    enum MediumType: Sendable {
        case solidState
        case rotational
        case unknown
    }
}

/// ソースの同時読み取りを絞るゲート(FolderSource 等が全読者に適用する)。
/// 待ち行列は 2 レーン: 表示中ページの読み込み(userInitiated 以上の Task)は
/// サムネイル生成(utility)の行列を追い越して先に許可される。これがないと
/// 低速媒体でページ表示がサムネイルの後ろに数秒並ばされる。
/// limit の縮小は実行中の読者には作用しない(次の acquire から効く)
/// EN: Concurrency gate with two lanes: interactive readers (page display,
/// EN: userInitiated and above) overtake queued background work (thumbnail
/// EN: generation runs at utility). Shrinking the limit affects future
/// EN: acquires only.
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
        let interactive = Task.currentPriority >= .userInitiated
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
