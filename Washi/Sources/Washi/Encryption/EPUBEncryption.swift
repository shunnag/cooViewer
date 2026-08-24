import CryptoKit
import Foundation

/// META-INF/encryption.xml の解析結果(EPUB 3.3 OCF §4)。
/// EPUB で実際に流通する「暗号化」は次の 3 系統:
/// 1. IDPF/Adobe のフォント難読化(DRM ではない。RS が自力で解除する義務)
/// 2. Adobe ADEPT / Readium LCP 等の本物の DRM(鍵がないので開けない)
/// 3. まれに独自方式
/// Washi は 1 を透過的に解除し、2・3 は対象リソースを識別してエラーにする。
public struct EPUBEncryptionInfo: Sendable {
    /// 難読化アルゴリズム
    public enum ObfuscationAlgorithm: String, Sendable {
        /// IDPF 標準(SHA-1 鍵 20 バイト・先頭 1040 バイトを XOR)
        case idpf = "http://www.idpf.org/2008/embedding"
        /// Adobe 方式(UUID 鍵 16 バイト・先頭 1024 バイトを XOR)
        case adobe = "http://ns.adobe.com/pdf/enc#RC"
    }

    /// コンテナ内パス(正規形)→ 難読化アルゴリズム
    public let obfuscatedResources: [String: ObfuscationAlgorithm]
    /// 未知アルゴリズムで暗号化されたリソース(パス → Algorithm URI)。
    /// spine コンテンツが含まれる場合は DRM 保護と判断する材料になる
    public let unknownEncryptedResources: [String: String]

    public var isEmpty: Bool {
        obfuscatedResources.isEmpty && unknownEncryptedResources.isEmpty
    }

    static let empty = EPUBEncryptionInfo(obfuscatedResources: [:],
                                          unknownEncryptedResources: [:])

    /// META-INF/encryption.xml を解析する
    static func parse(data: Data) throws -> EPUBEncryptionInfo {
        let document = try WashiXML.document(from: data)
        guard let root = document.rootElement() else {
            throw EPUBError.malformed("encryption.xml")
        }
        var obfuscated: [String: ObfuscationAlgorithm] = [:]
        var unknown: [String: String] = [:]
        for encryptedData in root.wsChildren("EncryptedData", ns: XMLNamespace.xmlEnc) {
            guard let algorithm = encryptedData
                .wsFirst("EncryptionMethod", ns: XMLNamespace.xmlEnc)?
                .attr("Algorithm") else { continue }
            guard let uri = encryptedData
                .wsFirst("CipherData", ns: XMLNamespace.xmlEnc)?
                .wsFirst("CipherReference", ns: XMLNamespace.xmlEnc)?
                .attr("URI") else { continue }
            // CipherReference URI はコンテナルート相対
            let path = ContainerPath.normalize(uri)
            if let known = ObfuscationAlgorithm(rawValue: algorithm) {
                obfuscated[path] = known
            } else {
                unknown[path] = algorithm
            }
        }
        return EPUBEncryptionInfo(obfuscatedResources: obfuscated,
                                  unknownEncryptedResources: unknown)
    }
}

/// フォント難読化(font mangling)の解除。
/// 難読化は「先頭 n バイトを識別子由来の鍵で XOR」しただけの可逆変換で、
/// 解除鍵は本の unique-identifier から導出する(EPUB 3.3 OCF §4.4)
public enum FontDeobfuscator {
    /// IDPF 方式の鍵: unique-identifier から全空白(スペース・タブ・CR・LF)を
    /// 除去した UTF-8 バイト列の SHA-1(20 バイト)
    public static func idpfKey(uniqueIdentifier: String) -> Data {
        let stripped = uniqueIdentifier.unicodeScalars
            .filter { !["\u{20}", "\u{9}", "\u{D}", "\u{A}"].contains(Character($0)) }
            .map(Character.init)
        let cleaned = String(stripped)
        let digest = Insecure.SHA1.hash(data: Data(cleaned.utf8))
        return Data(digest)
    }

    /// Adobe 方式の鍵: 識別子の "urn:uuid:" 接頭辞・ハイフン・空白を除いた
    /// 32 桁 16 進を 16 バイトへデコードしたもの
    public static func adobeKey(uniqueIdentifier: String) -> Data? {
        var cleaned = uniqueIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["urn:uuid:", "urn:UUID:"] where cleaned.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count))
        }
        cleaned = cleaned.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard cleaned.count == 32 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// 難読化データの解除(XOR は対合なので適用 = 解除)
    public static func deobfuscate(
        _ data: Data, algorithm: EPUBEncryptionInfo.ObfuscationAlgorithm,
        uniqueIdentifier: String) -> Data {
        let key: Data?
        let prefixLength: Int
        switch algorithm {
        case .idpf:
            key = idpfKey(uniqueIdentifier: uniqueIdentifier)
            prefixLength = 1040
        case .adobe:
            key = adobeKey(uniqueIdentifier: uniqueIdentifier)
            prefixLength = 1024
        }
        guard let key, !key.isEmpty else { return data }
        var result = data
        let count = min(prefixLength, result.count)
        result.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            key.withUnsafeBytes { (keyBytes: UnsafeRawBufferPointer) in
                for i in 0..<count {
                    bytes[i] ^= keyBytes[i % key.count]
                }
            }
        }
        return result
    }
}
