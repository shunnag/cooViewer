import CoreML
import CryptoKit
import Foundation

/// ML モデルの導入状態(設定 UI が表示するためのブリッジ)。
/// 実体は MLModelInstaller(actor)が更新する
@MainActor
final class MLModelInstallStatus: ObservableObject {
    enum State {
        case notInstalled
        case downloading
        case ready
        case failed
    }

    @Published var state: State = .notInstalled

    nonisolated init() {}

    /// 圧縮ノイズ低減「強」(waifu2x)の状態
    nonisolated static let noise = MLModelInstallStatus()
    /// 圧縮ノイズ低減「最高」(Real-ESRGAN ×4)の状態
    nonisolated static let superResolution = MLModelInstallStatus()
}

/// ML モデルの取得・検証・コンパイル・ロードの共通処理。
/// モデルはアプリに同梱せず**必要時にのみ**ダウンロードし、SHA-256 を
/// ピン留めして検証のうえ Application Support/Models にキャッシュする。
/// XCTest 実行ではネットワークに触れない方針のため常に失敗扱い
actor MLModelInstaller {
    struct Specification: Sendable {
        let downloadURL: URL
        let sha256: String
        /// 保存ファイル名(.mlmodel。コンパイル結果は .mlmodelc を付けて並置)
        let fileName: String
    }

    /// ロード済みモデルの持ち運び用。MLModel は Sendable 宣言されていないが
    /// prediction はスレッド安全(Apple のドキュメント明記)なので、
    /// アクタ境界を越えて渡すためにここで明示的に保証する
    struct LoadedModel: @unchecked Sendable {
        let model: MLModel
    }

    private let specification: Specification
    private let status: MLModelInstallStatus
    private var model: LoadedModel?
    private var installing = false

    init(specification: Specification, status: MLModelInstallStatus) {
        self.specification = specification
        self.status = status
    }

    private var modelDirectory: URL {
        FileManager.default
            .userDomainDirectory(.applicationSupportDirectory)
            .appendingPathComponent("jp.coo.cooViewer/Models")
    }

    private var modelFileURL: URL {
        modelDirectory.appendingPathComponent(specification.fileName)
    }

    private var compiledURL: URL {
        modelDirectory.appendingPathComponent(specification.fileName + "c")
    }

    private func setStatus(_ state: MLModelInstallStatus.State) {
        let status = status
        Task { @MainActor in
            status.state = state
        }
    }

    /// モデルを使える状態にしてロード済みインスタンスを返す
    /// (必要ならダウンロード→検証→コンパイル→ロード)。失敗時は nil
    func ensureModel() async -> LoadedModel? {
        if let model { return model }
        guard !installing else { return nil }
        guard !AutomatedRun.isXCTest else {
            setStatus(.failed)
            return nil
        }
        installing = true
        defer { installing = false }

        let fileManager = FileManager.default
        do {
            // 1. ダウンロード(既存の検証済みファイルがあれば再利用)
            if !fileManager.fileExists(atPath: modelFileURL.path) || !verifyHash() {
                setStatus(.downloading)
                let (data, _) = try await URLSession.shared.data(
                    from: specification.downloadURL)
                let digest = SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }.joined()
                guard digest == specification.sha256 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try fileManager.createDirectory(
                    at: modelDirectory, withIntermediateDirectories: true)
                try data.write(to: modelFileURL, options: .atomic)
                try? fileManager.removeItem(at: compiledURL)  // 再コンパイルさせる
            }
            // 2. コンパイル(結果はキャッシュして使い回す)
            if !fileManager.fileExists(atPath: compiledURL.path) {
                let compiled = try await MLModel.compileModel(at: modelFileURL)
                try? fileManager.removeItem(at: compiledURL)
                try fileManager.moveItem(at: compiled, to: compiledURL)
            }
            // 3. ロード(Neural Engine を含む全ユニットを許可)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let loaded = LoadedModel(model: try MLModel(
                contentsOf: compiledURL, configuration: configuration))
            model = loaded
            setStatus(.ready)
            return loaded
        } catch {
            setStatus(.failed)
            return nil
        }
    }

    private func verifyHash() -> Bool {
        guard let data = try? Data(contentsOf: modelFileURL) else { return false }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        return digest == specification.sha256
    }
}
