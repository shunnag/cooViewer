import SwiftUI

/// 設定「本」ペインのパスワードセクション(設計書 §2.4 パスワードマネージャー)。
/// 自動解錠のトグル・保存件数・全削除。トグル OFF は照会を止めるだけで
/// 保存データは消さない(削除は「すべて削除…」に分離)
struct PasswordVaultSection: View {
    private enum VaultState {
        case loading
        case unavailable
        case available(Int)
    }

    @AppStorage("PasswordVaultEnabled") private var vaultEnabled = true
    @State private var state: VaultState = .loading
    @State private var confirmsDeleteAll = false
    @State private var confirmsReset = false

    var body: some View {
        Section {
            Toggle(String(localized: "Unlock with saved passwords"), isOn: $vaultEnabled)
            HStack {
                switch state {
                case .loading:
                    Spacer()
                    Button(String(localized: "Delete All…")) {}
                        .disabled(true)
                case .unavailable:
                    Text(String(localized: "Saved passwords: unavailable"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "Reset Vault"), role: .destructive) {
                        confirmsReset = true
                    }
                case let .available(savedCount):
                    Text(String(localized: "Saved passwords: \(savedCount)"))
                    Spacer()
                    Button(String(localized: "Delete All…")) { confirmsDeleteAll = true }
                        .disabled(savedCount == 0)
                }
            }
        } header: {
            Text(String(localized: "Passwords"))
        } footer: {
            Text(String(localized: "Passwords you choose to save are encrypted with a key in your login keychain and never written to disk in plain text."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await refresh() }
        .alert(String(localized: "Delete all saved passwords?"),
               isPresented: $confirmsDeleteAll) {
            Button(String(localized: "Delete All"), role: .destructive) {
                Task {
                    await PasswordVault.shared.deleteAll()
                    await refresh()
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Encrypted books will ask for their passwords again. This cannot be undone."))
        }
        .alert(String(localized: "Reset broken vault"),
               isPresented: $confirmsReset) {
            Button(String(localized: "Reset Vault"), role: .destructive) {
                Task {
                    await PasswordVault.shared.deleteAll()
                    await refresh()
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "This empties and reinitializes the vault that cannot be decrypted. All saved passwords will be lost and cannot be recovered."))
        }
    }

    private func refresh() async {
        if await PasswordVault.shared.isAvailable() {
            state = .available(await PasswordVault.shared.count())
        } else {
            state = .unavailable
        }
    }
}
