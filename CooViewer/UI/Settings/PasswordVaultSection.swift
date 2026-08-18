import SwiftUI

/// 設定「本」ペインのパスワードセクション(設計書 §2.4 パスワードマネージャー)。
/// 自動解錠のトグル・保存件数・全削除。トグル OFF は照会を止めるだけで
/// 保存データは消さない(削除は「すべて削除…」に分離)
struct PasswordVaultSection: View {
    @AppStorage("PasswordVaultEnabled") private var vaultEnabled = true
    @State private var savedCount: Int?
    @State private var confirmsDeleteAll = false

    var body: some View {
        Section {
            Toggle(String(localized: "Unlock with saved passwords"), isOn: $vaultEnabled)
            HStack {
                if let savedCount {
                    Text(String(localized: "Saved passwords: \(savedCount)"))
                } else {
                    Text(String(localized: "Saved passwords: unavailable"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Delete All…")) { confirmsDeleteAll = true }
                    .disabled((savedCount ?? 0) == 0)
            }
        } header: {
            Text(String(localized: "Passwords"))
        } footer: {
            Text(String(localized: "Passwords you choose to save are encrypted with a key in your login keychain and never written to disk in plain text."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await refreshCount() }
        .alert(String(localized: "Delete all saved passwords?"),
               isPresented: $confirmsDeleteAll) {
            Button(String(localized: "Delete All"), role: .destructive) {
                Task {
                    await PasswordVault.shared.deleteAll()
                    await refreshCount()
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Encrypted books will ask for their passwords again. This cannot be undone."))
        }
    }

    private func refreshCount() async {
        let available = await PasswordVault.shared.isAvailable()
        savedCount = available ? await PasswordVault.shared.count() : nil
    }
}
