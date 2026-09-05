import Foundation
import Washi

/// EPUB 書名を AppKit のウインドウ題名に安全に埋め込むための整形。
enum EPUBTitleFormatter {
    private static let leftToRightIsolate = "\u{2066}"
    private static let rightToLeftIsolate = "\u{2067}"
    private static let firstStrongIsolate = "\u{2068}"
    private static let popDirectionalIsolate = "\u{2069}"

    /// 明示方向は LRI/RLI、自動または未指定の RTL 書名は FSI で
    /// 囲み、合本名や AppKit 由来の記号へ方向が漏れるのを防ぐ
    /// (cooViewer-oxr.52、設計書 §2.4)。
    static func windowTitle(_ title: String,
                            direction: EPUBTextDirection?) -> String {
        let opener: String?
        switch direction {
        case .rtl:
            opener = rightToLeftIsolate
        case .ltr:
            opener = leftToRightIsolate
        case .auto, nil:
            opener = containsStrongRTLCharacter(in: title)
                ? firstStrongIsolate : nil
        @unknown default:
            opener = containsStrongRTLCharacter(in: title)
                ? firstStrongIsolate : nil
        }
        guard let opener else { return title }
        return opener + title + popDirectionalIsolate
    }

    /// Unicode の強い RTL クラス R/AL を ICU のプロパティで
    /// 直接調べる。文字範囲の列挙では、符号の R を落とし、
    /// 結合文字の NSM を誤って拾う(cooViewer-oxr.52、設計書 §2.4)。
    private static func containsStrongRTLCharacter(in text: String) -> Bool {
        text.range(
            of: #"[\p{Bidi_Class=Right_To_Left}\p{Bidi_Class=Arabic_Letter}]"#,
            options: .regularExpression) != nil
    }
}
