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
    }
}
