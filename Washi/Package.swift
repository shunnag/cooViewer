// swift-tools-version: 6.0
// Washi — macOS ネイティブ技術だけで実装する EPUB 3 ツールキット。
// 依存パッケージゼロを設計原則とする。2 層のターゲットに分割する:
//   - WashiCore: 解析層(Foundation / Compression / CryptoKit / CoreGraphics /
//     ImageIO のみ)。OCF/OPF/nav 解析・メタデータ・本文抽出/検索・表紙デコード
//     まで。GUI セッションのないヘッドレス利用(CLI・索引・サーバ)で使える。
//   - Washi: 表示層(AppKit / WebKit を追加)。リフロー/FXL リーダービュー・
//     ページ census・サムネイル。WashiCore を @_exported 再輸出するので、
//     `import Washi` だけで両層の公開 API が見える(従来互換)。
// cooViewer から独立した MIT ライセンスのパッケージであり、単体で再利用できる。
import PackageDescription

let package = Package(
    name: "Washi",
    platforms: [
        // WKWebView.takeSnapshot / WKURLSchemeHandler / XMLDocument が揃う範囲で
        // できるだけ広く(cooViewer 本体は macOS 26+ だが、パッケージ単体は
        // 他アプリからの再利用を考慮して macOS 14+ とする)
        .macOS(.v14)
    ],
    products: [
        // 解析層のみ(ヘッドレス利用向け)
        .library(name: "WashiCore", targets: ["WashiCore"]),
        // 表示層込み(WashiCore を再輸出)
        .library(name: "Washi", targets: ["Washi"]),
        // cooViewer 用: Washi.framework を組み立てる材料の dylib。両ターゲットを
        // 1 つの動的ライブラリへまとめる(Scripts/build-washi-framework.sh が使う。
        // SwiftPM 利用者は上の automatic ライブラリをそのまま使えばよい)
        .library(name: "WashiDynamic", type: .dynamic,
                 targets: ["WashiCore", "Washi"]),
    ],
    targets: [
        .target(
            name: "WashiCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "Washi",
            dependencies: ["WashiCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "WashiTests",
            dependencies: ["Washi", "WashiCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
