import WebKit

/// cooViewer-oxr.87: 著者スクリプトを許可したページから WebRTC の
/// STUN/UDP 経路を使えないよう、ページ世界の RTC コンストラクタだけを塞ぐ。
@MainActor
enum EPUBScriptedContentHardening {
    static let source = #"""
    (function () {
        'use strict';
        const names = [
            'RTCPeerConnection',
            'webkitRTCPeerConnection',
            'RTCDataChannel',
            'RTCSessionDescription',
            'RTCIceCandidate',
            'RTCPeerConnectionIceEvent'
        ];
        for (const target of [window, globalThis]) {
            for (const name of names) {
                try {
                    Object.defineProperty(target, name, {
                        value: undefined,
                        writable: false,
                        enumerable: false,
                        configurable: false
                    });
                } catch (_) {
                    // 個別 API の差異で残りのコンストラクタまで処理を止めない。
                }
            }
        }
    })();
    """#

    static func install(
        in controller: WKUserContentController,
        allowsScriptedContent: Bool
    ) {
        guard allowsScriptedContent else { return }
        controller.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page))
        controller.addUserScript(WKUserScript(
            source: readingSystemSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page))
    }

    /// cooViewer-oxr.46 C50 / RS 3.3 6.4: scripted content を許可するなら
    /// navigator.epubReadingSystem を提供しなければならない(MUST)。
    /// 著者スクリプトから見える必要があるので page world へ入れる。
    /// 機能表明は Washi の実際の対応に合わせる(嘘をつくと本側が誤った分岐を
    /// 選ぶ。touch-events は macOS の WKWebView では発火しない)。
    static let readingSystemSource = """
        (function () {
            const features = {
                'dom-manipulation': true,
                'layout-changes': true,
                'touch-events': false,
                'mouse-events': true,
                'keyboard-events': true,
                'spine-scripting': true
            };
            const system = {
                name: 'Washi',
                version: '\(EPUBReadingSystem.version)',
                layoutStyle: 'paginated',
                hasFeature: function (feature, version) {
                    if (version !== undefined && version !== null
                        && String(version) !== '1.0') { return false; }
                    return features[feature] === true;
                }
            };
            try {
                Object.defineProperty(navigator, 'epubReadingSystem', {
                    value: Object.freeze(system),
                    writable: false, configurable: false, enumerable: true
                });
            } catch (e) { /* 既に定義済みなら触らない */ }
        })();
        """
}

/// 読書システムとしての自己申告(navigator.epubReadingSystem に出る)
public enum EPUBReadingSystem {
    /// パッケージの版に合わせて更新する
    public static let version = "1.17.0"
}
