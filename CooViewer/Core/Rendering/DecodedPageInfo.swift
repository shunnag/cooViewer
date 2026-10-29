import CoreGraphics

/// 設計書 §5: 画素を保持せずに、元画像と同じリサンプルキー・配置・先読み予算を再現する。
struct DecodedPageInfo: Sendable, Equatable {
    let width: Int
    let height: Int
    let colorSpaceIdentity: String
    let byteCost: Int
    let preservesHDR: Bool

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        colorSpaceIdentity = image.colorSpace.map(DisplayColorTarget.identity) ?? "none"
        byteCost = image.bytesPerRow * image.height
        preservesHDR = DisplayColorTarget.preservesHDR(image)
    }

    var size: CGSize { CGSize(width: width, height: height) }
}
