import Foundation

/// ZIP エントリ検証用の CRC-32(IEEE 802.3 多項式 0xEDB88320)。
/// zlib には Swift から直接触れないため自前実装(テーブル 1 本の素朴な方式で、
/// EPUB 内のリソース規模(高々数十 MB)には十分な速度)。
enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
