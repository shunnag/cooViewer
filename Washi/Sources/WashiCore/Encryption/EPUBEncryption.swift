import CryptoKit
import Foundation

/// Parsed result of META-INF/encryption.xml (EPUB 3.3 OCF §4).
/// The "encryption" that actually circulates in EPUBs falls into three families:
/// 1. IDPF/Adobe font obfuscation (not DRM; the reading system is obligated to undo it itself)
/// 2. Genuine DRM such as Adobe ADEPT or Readium LCP (no key, so it cannot be opened)
/// 3. Rarely, a proprietary scheme
/// Washi transparently undoes family 1, and for families 2 and 3 it identifies the affected
/// resources and reports an error.
public struct EPUBEncryptionInfo: Sendable {
    /// Obfuscation algorithm.
    public enum ObfuscationAlgorithm: String, Sendable {
        /// IDPF standard (20-byte SHA-1 key, XOR over the first 1040 bytes).
        case idpf = "http://www.idpf.org/2008/embedding"
        /// Adobe scheme (16-byte UUID key, XOR over the first 1024 bytes).
        case adobe = "http://ns.adobe.com/pdf/enc#RC"
    }

    /// Container-internal path (normalized) → obfuscation algorithm.
    public let obfuscatedResources: [String: ObfuscationAlgorithm]
    /// Resources encrypted with an unknown algorithm (path → Algorithm URI).
    /// When spine content is among them, this is evidence that the book is DRM-protected.
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

/// Reversal of font mangling (font obfuscation).
/// Obfuscation is merely a reversible transform that XORs the first n bytes with an
/// identifier-derived key; the key is derived from the book's unique-identifier (EPUB 3.3 OCF §4.4).
public enum FontDeobfuscator {
    /// IDPF-scheme key: the SHA-1 (20 bytes) of the UTF-8 byte sequence of the
    /// unique-identifier with all whitespace (space, tab, CR, LF) removed.
    public static func idpfKey(uniqueIdentifier: String) -> Data {
        let stripped = uniqueIdentifier.unicodeScalars
            .filter { !["\u{20}", "\u{9}", "\u{D}", "\u{A}"].contains(Character($0)) }
            .map(Character.init)
        let cleaned = String(stripped)
        let digest = Insecure.SHA1.hash(data: Data(cleaned.utf8))
        return Data(digest)
    }

    /// Adobe-scheme key: the identifier's 32 hex digits — with the "urn:uuid:" prefix,
    /// hyphens, and whitespace removed — decoded into 16 bytes.
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

    /// Undo obfuscated data (XOR is an involution, so applying it equals undoing it).
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
