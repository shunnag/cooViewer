import Compression
import Foundation

/// An error raised while reading a ZIP (OCF) container.
public enum ZipError: Error, Sendable, Equatable, LocalizedError {
    /// Not a ZIP file (no end-of-central-directory record was found).
    case notAZipFile
    /// The archive is truncated or structurally broken. The string names where.
    case truncated(String)
    /// The entry uses a compression method other than store (0) or deflate (8).
    case unsupportedCompressionMethod(UInt16, entry: String)
    /// A ZIP-level encrypted entry (distinct from EPUB DRM; not used by valid
    /// EPUBs).
    case encryptedEntryUnsupported(String)
    /// Multi-volume (spanned) archives are not supported.
    case multiDiskUnsupported
    /// The named entry does not exist.
    case entryNotFound(String)
    /// The inflated data failed its size or CRC-32 check.
    case corruptEntry(String)
    /// The declared uncompressed size exceeds `ZipArchive.maxEntrySize`.
    /// The 1032:1 ratio check alone cannot stop a genuine high-ratio deflate
    /// stream (e.g. zeros) from forcing a huge allocation, so an absolute cap
    /// guards it. `declaredSize` is the size the archive claimed.
    case entryTooLarge(String, declaredSize: UInt64)

    public var errorDescription: String? {
        switch self {
        case .notAZipFile:
            return "Not a ZIP/EPUB file."
        case .truncated(let detail):
            return "Truncated or broken ZIP: \(detail)"
        case .unsupportedCompressionMethod(let method, let entry):
            return "Unsupported compression method \(method) in entry: \(entry)"
        case .encryptedEntryUnsupported(let entry):
            return "ZIP-level encrypted entry is not supported: \(entry)"
        case .multiDiskUnsupported:
            return "Multi-volume ZIP archives are not supported."
        case .entryNotFound(let entry):
            return "Entry not found: \(entry)"
        case .corruptEntry(let entry):
            return "Corrupt entry (size or CRC mismatch): \(entry)"
        case .entryTooLarge(let entry, let size):
            return "Entry exceeds the size limit (\(size) bytes declared): \(entry)"
        }
    }
}

/// Metadata for a single entry within a ZIP archive.
public struct ZipEntryInfo: Sendable, Hashable {
    public let name: String
    public let isDirectory: Bool
    public let compressedSize: UInt64
    public let uncompressedSize: UInt64
    /// Compression method (0 = store / 8 = deflate).
    public let method: UInt16
    let crc32: UInt32
    let localHeaderOffset: UInt64
    /// 汎用フラグ(bit0=暗号化, bit11=UTF-8 名)
    let flags: UInt16
}

/// A read-only ZIP reader for EPUB (OCF ZIP) containers.
/// To honor the zero-dependency policy it avoids XADMaster and the like,
/// building only on Foundation + Compression. Its scope matches what EPUBs
/// actually use: store/deflate, zip64, and UTF-8 names (non-UTF-8 names fall
/// back to Shift_JIS). ZIP encryption and multi-volume archives are
/// unsupported (they raise an explicit error).
///
/// The whole file is held as `Data` (mappedIfSafe), and init parses only the
/// central directory. Every subsequent read is a pure function over that
/// immutable data, so it is thread-safe (Sendable). Entry names are never used
/// for any path operation (no zip-slip concern).
public final class ZipArchive: Sendable {
    /// Default upper bound for a single entry's inflated size (512 MB). This is
    /// comfortably wide for real-world EPUBs, where no single file exceeds it
    /// even with images, audio, and video included.
    public static let defaultMaxEntrySize = 512 << 20

    private let data: Data
    public let entries: [ZipEntryInfo]
    /// 正確な名前 → entries 添字(OCF はケースセンシティブ。重複名は先勝ち)
    private let index: [String: Int]
    /// 1 エントリの展開後サイズ上限(超えると entryTooLarge)
    private let maxEntrySize: Int

    public convenience init(url: URL,
                            maxEntrySize: Int = ZipArchive.defaultMaxEntrySize) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try self.init(data: data, maxEntrySize: maxEntrySize)
    }

    public init(data: Data,
                maxEntrySize: Int = ZipArchive.defaultMaxEntrySize) throws {
        self.data = data
        self.maxEntrySize = maxEntrySize
        let reader = ByteReader(data: data)
        let eocd = try Self.locateEndOfCentralDirectory(reader)
        // 偽装 zip64 対策: 中央ディレクトリエントリは最低 46 バイトなので、
        // ファイルサイズから見て不可能な件数は不正(巨大 reserveCapacity で
        // 落とされない)
        guard eocd.entryCount <= UInt64(reader.count / 46) else {
            throw ZipError.truncated("entry count")
        }
        var entries: [ZipEntryInfo] = []
        entries.reserveCapacity(Int(eocd.entryCount))
        var index: [String: Int] = [:]
        var offset = eocd.centralDirectoryOffset
        for _ in 0..<eocd.entryCount {
            let (entry, next) = try Self.parseCentralDirectoryEntry(reader, at: offset)
            if index[entry.name] == nil {
                index[entry.name] = entries.count
                entries.append(entry)
            }
            offset = next
        }
        self.entries = entries
        self.index = index
    }

    public func contains(_ name: String) -> Bool { index[name] != nil }

    public func info(for name: String) -> ZipEntryInfo? {
        index[name].map { entries[$0] }
    }

    /// Inflates the entry and returns it. Store copies the slice; deflate is
    /// decoded in one shot. The result is always verified against its CRC-32, so
    /// silent corruption is caught reliably before it surfaces as an EPUB parse
    /// failure.
    public func data(forEntry name: String) throws -> Data {
        guard let info = info(for: name) else { throw ZipError.entryNotFound(name) }
        if info.isDirectory { return Data() }
        guard info.flags & 0x0001 == 0 else {
            throw ZipError.encryptedEntryUnsupported(name)
        }

        // ローカルヘッダの名前長/拡張長は中央ディレクトリと異なることがあるため
        // 必ずローカルヘッダを読み直してデータ開始位置を求める。
        // 偽装 zip64 の巨大値は Int 変換・加算でトラップさせず不正として弾く
        let reader = ByteReader(data: data)
        guard let lho = Int(exactly: info.localHeaderOffset),
              let compressedSize = Int(exactly: info.compressedSize),
              let uncompressedSize = Int(exactly: info.uncompressedSize),
              lho <= reader.count, compressedSize <= reader.count else {
            throw ZipError.truncated("entry sizes: \(name)")
        }
        // 宣言サイズの絶対上限。比率検査(deflate 1032:1)だけでは
        // ゼロ埋め等の正規高圧縮データで巨大確保を強制できる
        guard uncompressedSize <= maxEntrySize else {
            throw ZipError.entryTooLarge(name, declaredSize: info.uncompressedSize)
        }
        guard try reader.u32(at: lho) == 0x0403_4B50 else {
            throw ZipError.truncated("local header: \(name)")
        }
        let nameLength = Int(try reader.u16(at: lho + 26))
        let extraLength = Int(try reader.u16(at: lho + 28))
        let dataStart = lho + 30 + nameLength + extraLength
        let compressed = try reader.slice(at: dataStart, count: compressedSize)

        let raw: Data
        switch info.method {
        case 0:
            guard compressedSize == uncompressedSize else {
                throw ZipError.corruptEntry(name)
            }
            raw = compressed
        case 8:
            // zip 爆弾対策: deflate の理論最大圧縮率は 1032:1。それを超える
            // 宣言サイズは不正(攻撃者制御の中央ディレクトリ値で巨大確保しない。
            // compressedSize はファイルサイズ以下を検証済みなので乗算は溢れない)
            guard uncompressedSize <= compressedSize * 1032 + 1024 else {
                throw ZipError.corruptEntry(name)
            }
            raw = try Self.inflate(compressed, uncompressedSize: uncompressedSize,
                                   entryName: name)
        default:
            throw ZipError.unsupportedCompressionMethod(info.method, entry: name)
        }
        guard CRC32.checksum(raw) == info.crc32 else {
            throw ZipError.corruptEntry(name)
        }
        return raw
    }

    // MARK: - 中央ディレクトリの解析

    private struct EndOfCentralDirectory {
        var entryCount: UInt64
        var centralDirectoryOffset: Int
    }

    private static func locateEndOfCentralDirectory(
        _ reader: ByteReader) throws -> EndOfCentralDirectory {
        // EOCD(22 バイト固定 + コメント最大 65535)を末尾から後方走査
        let minEOCD = 22
        guard reader.count >= minEOCD else { throw ZipError.notAZipFile }
        let scanStart = max(0, reader.count - minEOCD - 0xFFFF)
        var eocdOffset = -1
        var pos = reader.count - minEOCD
        while pos >= scanStart {
            if (try? reader.u32(at: pos)) == 0x0605_4B50 {
                // コメント長がファイル末尾と整合する位置だけを EOCD と認める
                // (コメント内に偶然シグネチャが現れる場合の誤認を防ぐ)
                if let commentLength = try? reader.u16(at: pos + 20),
                   pos + minEOCD + Int(commentLength) == reader.count {
                    eocdOffset = pos
                    break
                }
            }
            pos -= 1
        }
        guard eocdOffset >= 0 else { throw ZipError.notAZipFile }

        let diskNumber = try reader.u16(at: eocdOffset + 4)
        let cdDisk = try reader.u16(at: eocdOffset + 6)
        var entryCount = UInt64(try reader.u16(at: eocdOffset + 10))
        var cdOffset = UInt64(try reader.u32(at: eocdOffset + 16))

        let needsZip64 = entryCount == 0xFFFF || cdOffset == 0xFFFF_FFFF
            || diskNumber == 0xFFFF || cdDisk == 0xFFFF
        if needsZip64 {
            // zip64 EOCD locator は EOCD の直前 20 バイト
            let locator = eocdOffset - 20
            guard locator >= 0, try reader.u32(at: locator) == 0x0706_4B50 else {
                throw ZipError.truncated("zip64 locator")
            }
            // 攻撃者制御の 64bit オフセットを Int(...) で変換するとオーバー
            // フローでトラップ(SIGTRAP)する。data(forEntry:) と同じく
            // Int(exactly:) + 範囲検査で不正値は例外として弾く(zip64 EOCD は
            // 56 バイトぶん読むので末尾まで在ることを要求する)
            guard let zip64Offset = Int(exactly: try reader.u64(at: locator + 8)),
                  zip64Offset >= 0, zip64Offset <= reader.count - 56 else {
                throw ZipError.truncated("zip64 EOCD offset")
            }
            guard try reader.u32(at: zip64Offset) == 0x0606_4B50 else {
                throw ZipError.truncated("zip64 EOCD")
            }
            let zDisk = try reader.u32(at: zip64Offset + 16)
            let zCDDisk = try reader.u32(at: zip64Offset + 20)
            guard zDisk == 0, zCDDisk == 0 else { throw ZipError.multiDiskUnsupported }
            entryCount = try reader.u64(at: zip64Offset + 32)
            cdOffset = try reader.u64(at: zip64Offset + 48)
        } else {
            guard diskNumber == 0, cdDisk == 0 else { throw ZipError.multiDiskUnsupported }
        }
        guard cdOffset < UInt64(reader.count) else {
            throw ZipError.truncated("central directory offset")
        }
        return EndOfCentralDirectory(entryCount: entryCount,
                                     centralDirectoryOffset: Int(cdOffset))
    }

    private static func parseCentralDirectoryEntry(
        _ reader: ByteReader, at offset: Int) throws -> (ZipEntryInfo, next: Int) {
        guard try reader.u32(at: offset) == 0x0201_4B50 else {
            throw ZipError.truncated("central directory entry")
        }
        let flags = try reader.u16(at: offset + 8)
        let method = try reader.u16(at: offset + 10)
        let crc = try reader.u32(at: offset + 16)
        var compressedSize = UInt64(try reader.u32(at: offset + 20))
        var uncompressedSize = UInt64(try reader.u32(at: offset + 24))
        let nameLength = Int(try reader.u16(at: offset + 28))
        let extraLength = Int(try reader.u16(at: offset + 30))
        let commentLength = Int(try reader.u16(at: offset + 32))
        var diskStart = UInt64(try reader.u16(at: offset + 34))
        var localOffset = UInt64(try reader.u32(at: offset + 42))

        let nameData = try reader.slice(at: offset + 46, count: nameLength)
        // OCF 仕様はエントリ名 UTF-8 を要求するが、実在ファイルには CP932 名の
        // 不正 ZIP もあるため Shift_JIS → Latin-1 の順でフォールバックする
        let name: String
        if flags & 0x0800 != 0 {
            name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1) ?? ""
        } else {
            name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .shiftJIS)
                ?? String(data: nameData, encoding: .isoLatin1) ?? ""
        }

        // zip64 拡張フィールド(id 0x0001): 0xFFFFFFFF / 0xFFFF のフィールドだけが
        // 宣言順(usize, csize, offset, disk)に 64/32bit 値で並ぶ
        var extraOffset = offset + 46 + nameLength
        let extraEnd = extraOffset + extraLength
        while extraOffset + 4 <= extraEnd {
            let fieldID = try reader.u16(at: extraOffset)
            let fieldSize = Int(try reader.u16(at: extraOffset + 2))
            if fieldID == 0x0001 {
                var p = extraOffset + 4
                let fieldEnd = min(p + fieldSize, extraEnd)
                if uncompressedSize == 0xFFFF_FFFF, p + 8 <= fieldEnd {
                    uncompressedSize = try reader.u64(at: p); p += 8
                }
                if compressedSize == 0xFFFF_FFFF, p + 8 <= fieldEnd {
                    compressedSize = try reader.u64(at: p); p += 8
                }
                if localOffset == 0xFFFF_FFFF, p + 8 <= fieldEnd {
                    localOffset = try reader.u64(at: p); p += 8
                }
                if diskStart == 0xFFFF, p + 4 <= fieldEnd {
                    diskStart = UInt64(try reader.u32(at: p)); p += 4
                }
            }
            extraOffset += 4 + fieldSize
        }
        guard diskStart == 0 else { throw ZipError.multiDiskUnsupported }

        let entry = ZipEntryInfo(
            name: name,
            isDirectory: name.hasSuffix("/"),
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            method: method,
            crc32: crc,
            localHeaderOffset: localOffset,
            flags: flags
        )
        return (entry, offset + 46 + nameLength + extraLength + commentLength)
    }

    // MARK: - deflate 展開

    /// raw deflate ストリームの一括展開(Compression の COMPRESSION_ZLIB は
    /// zlib ヘッダなしの raw deflate を指す)。展開後サイズは中央ディレクトリの
    /// 値を信頼して一発確保する(EPUB のリソース規模なら問題ない)
    private static func inflate(_ compressed: Data, uncompressedSize: Int,
                                entryName: String) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        var result = Data(count: uncompressedSize)
        let written = result.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            compressed.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let dstBase = dst.baseAddress, let srcBase = src.baseAddress,
                      !compressed.isEmpty else { return 0 }
                return compression_decode_buffer(
                    dstBase.assumingMemoryBound(to: UInt8.self), uncompressedSize,
                    srcBase.assumingMemoryBound(to: UInt8.self), compressed.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == uncompressedSize else { throw ZipError.corruptEntry(entryName) }
        return result
    }
}

/// リトルエンディアン固定の境界チェック付きバイト読み取り
struct ByteReader {
    let data: Data
    var count: Int { data.count }

    private func byte(at offset: Int) -> UInt8 {
        data[data.startIndex + offset]
    }

    func u16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { throw ZipError.truncated("u16") }
        return UInt16(byte(at: offset)) | (UInt16(byte(at: offset + 1)) << 8)
    }

    func u32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw ZipError.truncated("u32") }
        return UInt32(byte(at: offset))
            | (UInt32(byte(at: offset + 1)) << 8)
            | (UInt32(byte(at: offset + 2)) << 16)
            | (UInt32(byte(at: offset + 3)) << 24)
    }

    func u64(at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { throw ZipError.truncated("u64") }
        var value: UInt64 = 0
        for i in (0..<8).reversed() {
            value = (value << 8) | UInt64(byte(at: offset + i))
        }
        return value
    }

    func slice(at offset: Int, count sliceCount: Int) throws -> Data {
        guard offset >= 0, sliceCount >= 0, offset + sliceCount <= count else {
            throw ZipError.truncated("slice")
        }
        let start = data.startIndex + offset
        return data.subdata(in: start..<(start + sliceCount))
    }
}
