import Foundation

/// 親フォルダ内の「本」一覧(仕様書 §4.1.4, §4.3.4 の次/前の本の母集団)。
/// 名前順(Finder 互換自然順)、ドット始まりは除外、ディレクトリまたは
/// 対応する本ファイルのみ。純関数なので任意のスレッドで走らせる。
enum SiblingBooks {
    static func scan(parent: URL, probe: any FileSystemProbing) -> [String] {
        guard let items = try? probe.directoryItems(at: parent) else { return [] }
        return items
            .filter { !$0.name.hasPrefix(".") }
            .filter { item in
                item.isDirectory
                    || SupportedTypes.isBookFile(parent.appendingPathComponent(item.name))
            }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { parent.appendingPathComponent($0).path }
    }
}
