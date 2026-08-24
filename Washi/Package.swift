// swift-tools-version: 6.0
// Washi — macOS ネイティブ技術だけで実装する EPUB 3 ツールキット。
// 依存パッケージゼロを設計原則とする(解析層は Foundation / Compression /
// CryptoKit / ImageIO のみ、表示層は AppKit / WebKit を追加)。
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
        .library(name: "Washi", targets: ["Washi"]),
        // cooViewer 用: Washi.framework を組み立てる材料の dylib
        // (Scripts/build-washi-framework.sh が使う。SwiftPM 利用者は上の
        // automatic ライブラリをそのまま使えばよい)
        .library(name: "WashiDynamic", type: .dynamic, targets: ["Washi"]),
    ],
    targets: [
        .target(
            name: "Washi",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "WashiTests",
            dependencies: ["Washi"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
