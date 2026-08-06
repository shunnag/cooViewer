import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// テスト用フィクスチャ生成ヘルパ。
enum TestFixtures {
    /// 単色 PNG データを生成する。
    static func pngData(width: Int, height: Int,
                        red: CGFloat = 0.5, green: CGFloat = 0.5, blue: CGFloat = 0.5) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!

        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// 一時ディレクトリを作る(テスト終了時に呼び出し側で削除)。
    static func makeTempDir(function: StaticString = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CooViewerTests-\(function)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 手組み ZIP(無圧縮)

    /// 任意のバイト列ファイル名を持つ ZIP を生成する。
    /// ファイル名エンコーディング検出(仕様書 §4.17)のテストのため、
    /// UTF-8 フラグを立てず DOS ホスト扱いで書き出す。
    static func storedZip(entries: [(nameBytes: [UInt8], data: Data)]) -> Data {
        var out = Data()
        var centralDirectory = Data()
        var offsets: [UInt32] = []

        for entry in entries {
            offsets.append(UInt32(out.count))
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            out.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])  // local file header
            out.appendLE16(20)                                 // version needed
            out.appendLE16(0)                                  // flags(UTF-8 フラグなし)
            out.appendLE16(0)                                  // method: stored
            out.appendLE16(0); out.appendLE16(0)               // time, date
            out.appendLE32(crc)
            out.appendLE32(size); out.appendLE32(size)
            out.appendLE16(UInt16(entry.nameBytes.count))
            out.appendLE16(0)                                  // extra len
            out.append(contentsOf: entry.nameBytes)
            out.append(entry.data)
        }

        for (index, entry) in entries.enumerated() {
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            centralDirectory.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            centralDirectory.appendLE16(20)                    // version made by(DOS ホスト)
            centralDirectory.appendLE16(20)                    // version needed
            centralDirectory.appendLE16(0)                     // flags
            centralDirectory.appendLE16(0)                     // method
            centralDirectory.appendLE16(0); centralDirectory.appendLE16(0)
            centralDirectory.appendLE32(crc)
            centralDirectory.appendLE32(size); centralDirectory.appendLE32(size)
            centralDirectory.appendLE16(UInt16(entry.nameBytes.count))
            centralDirectory.appendLE16(0); centralDirectory.appendLE16(0)  // extra, comment
            centralDirectory.appendLE16(0)                     // disk
            centralDirectory.appendLE16(0)                     // internal attrs
            centralDirectory.appendLE32(0)                     // external attrs
            centralDirectory.appendLE32(offsets[index])
            centralDirectory.append(contentsOf: entry.nameBytes)
        }

        let cdOffset = UInt32(out.count)
        out.append(centralDirectory)
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])       // end of central directory
        out.appendLE16(0); out.appendLE16(0)                   // disk numbers
        out.appendLE16(UInt16(entries.count)); out.appendLE16(UInt16(entries.count))
        out.appendLE32(UInt32(centralDirectory.count))
        out.appendLE32(cdOffset)
        out.appendLE16(0)                                      // comment len
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}

extension Data {
    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8(value >> 24))
    }
}

/// 再現可能なシャッフルテスト用の決定的乱数生成器。
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
