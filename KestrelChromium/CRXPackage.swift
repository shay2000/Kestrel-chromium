#if canImport(CryptoKit) && canImport(Security)

import CryptoKit
import Foundation
import Security

/// CRX3 authenticates the exact ZIP bytes and binds their developer key to the
/// signed extension ID. This does not establish Chrome Web Store provenance.
struct CRXPackage {
    let archive: Data
    let publicKey: Data
    let extensionID: String

    enum ValidationError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): return message }
        }
    }

    init(data: Data) throws {
        guard data.count <= 50 * 1_048_576, data.count >= 12,
              data.prefix(4) == Data("Cr24".utf8) else {
            throw ValidationError.invalid("The CRX package header is invalid or exceeds 50 MB.")
        }
        guard Self.uint32(data, at: 4) == 3 else {
            throw ValidationError.invalid("Only signed CRX3 packages are supported. Legacy CRX2 packages cannot be imported.")
        }
        let headerSize = Int(Self.uint32(data, at: 8))
        guard headerSize > 0, headerSize <= 1_000_000, headerSize < data.count - 12 else {
            throw ValidationError.invalid("The CRX3 header is incomplete or too large.")
        }
        let fields = try Self.fields(Data(data[12..<(12 + headerSize)]))
        let signedHeader = try Self.single(10000, in: fields)
        let id = try Self.single(1, in: Self.fields(signedHeader))
        guard id.count == 16 else { throw ValidationError.invalid("The signed CRX3 identity is invalid.") }
        let zip = Data(data.dropFirst(12 + headerSize))
        guard zip.starts(with: [0x50, 0x4b, 0x03, 0x04]) else {
            throw ValidationError.invalid("The signed CRX3 payload is not a ZIP archive.")
        }
        var message = Data("CRX3 SignedData\0".utf8)
        let size = UInt32(signedHeader.count)
        message.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) })
        message.append(signedHeader)
        message.append(zip)
        let proofs = fields.filter { $0.number == 2 || $0.number == 3 }
        guard !proofs.isEmpty, proofs.count <= 16 else {
            throw ValidationError.invalid("The CRX3 package has no supported signature or too many proofs.")
        }
        var developerKey: Data?
        for proof in proofs {
            let values = try Self.fields(proof.bytes)
            let key = try Self.single(1, in: values)
            let signature = try Self.single(2, in: values)
            guard key.count <= 16_384, signature.count <= 16_384,
                  Self.verify(signature: signature, message: message, key: key, rsa: proof.number == 2) else {
                throw ValidationError.invalid("The CRX3 signature could not be verified. The package may have been changed.")
            }
            if Data(SHA256.hash(data: key).prefix(16)) == id { developerKey = key }
        }
        guard let developerKey else {
            throw ValidationError.invalid("The CRX3 signing key does not match its signed extension identity.")
        }
        // Retain the payload from the owned buffer whose exact bytes were
        // verified, rather than a potentially file-backed view of the input.
        archive = Data(message.suffix(zip.count))
        publicKey = developerKey
        extensionID = id.flatMap { byte in [byte >> 4, byte & 15] }
            .map { String(UnicodeScalar(97 + Int($0))!) }.joined()
    }

    /// Chromium derives an unpacked extension's stable identity from `key`.
    /// Reject a conflicting key instead of silently changing the reviewed ID.
    func manifestPreservingIdentity(_ data: Data) throws -> Data {
        guard var manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValidationError.invalid("The extension manifest must be a JSON object.")
        }
        if let existing = manifest["key"] {
            guard let encoded = existing as? String,
                  Data(base64Encoded: encoded.filter { !$0.isWhitespace }) == publicKey else {
                throw ValidationError.invalid("The manifest key conflicts with the signed CRX3 identity.")
            }
        }
        manifest["key"] = publicKey.base64EncodedString()
        return try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    }

    private struct Field { let number: UInt64; let bytes: Data }

    /// Bounded protobuf wire reader: unknown ordinary fields are skipped, while
    /// duplicate/mistyped security fields, groups and overflowing lengths fail.
    private static func fields(_ data: Data) throws -> [Field] {
        let bytes = [UInt8](data)
        var offset = 0
        var result: [Field] = []
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard offset < bytes.count else { throw ValidationError.invalid("The CRX3 header is truncated.") }
                let byte = bytes[offset]; offset += 1
                guard index < 9 || byte <= 1 else { throw ValidationError.invalid("The CRX3 header contains an overflowing integer.") }
                value |= UInt64(byte & 127) << (index * 7)
                if byte & 128 == 0 { return value }
            }
            throw ValidationError.invalid("The CRX3 header contains an invalid integer.")
        }
        while offset < bytes.count {
            guard result.count < 4096 else { throw ValidationError.invalid("The CRX3 header contains too many fields.") }
            let tag = try varint()
            let number = tag >> 3
            guard number > 0, number <= 0x1fff_ffff else { throw ValidationError.invalid("The CRX3 field number is invalid.") }
            let length: UInt64
            switch tag & 7 {
            case 0: _ = try varint(); length = 0
            case 1: length = 8
            case 2: length = try varint()
            case 5: length = 4
            default: throw ValidationError.invalid("The CRX3 header uses an unsupported wire type.")
            }
            guard length <= UInt64(bytes.count - offset) else { throw ValidationError.invalid("The CRX3 field is truncated.") }
            result.append(Field(number: number, bytes: tag & 7 == 2 ? Data(bytes[offset..<(offset + Int(length))]) : Data()))
            offset += Int(length)
        }
        return result
    }

    private static func single(_ number: UInt64, in fields: [Field]) throws -> Data {
        let matches = fields.filter { $0.number == number }
        guard matches.count == 1, let field = matches.first, !field.bytes.isEmpty else {
            throw ValidationError.invalid("The CRX3 header has a missing, duplicate or invalid signing field.")
        }
        return field.bytes
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
    }

    private static func verify(signature: Data, message: Data, key: Data, rsa: Bool) -> Bool {
        if !rsa {
            guard let publicKey = try? P256.Signing.PublicKey(derRepresentation: key),
                  let signature = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
            return publicKey.isValidSignature(signature, for: message)
        }
        // Security accepts PKCS#1 RSA public keys; CRX3 stores X.509 SPKI.
        guard let pkcs1 = rsaPublicKey(from: key),
              let publicKey = SecKeyCreateWithData(pkcs1 as CFData, [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: kSecAttrKeyClassPublic
              ] as CFDictionary, nil),
              SecKeyIsAlgorithmSupported(publicKey, .verify, .rsaSignatureMessagePKCS1v15SHA256) else { return false }
        return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                     message as CFData, signature as CFData, nil)
    }

    private static func rsaPublicKey(from spki: Data) -> Data? {
        let bytes = [UInt8](spki)
        var offset = 0
        func element(_ tag: UInt8) -> Range<Int>? {
            guard offset + 2 <= bytes.count, bytes[offset] == tag else { return nil }
            offset += 1
            var length = Int(bytes[offset]); offset += 1
            if length & 128 != 0 {
                let count = length & 127
                guard count > 0, count <= 4, offset + count <= bytes.count, bytes[offset] != 0 else { return nil }
                length = 0
                for _ in 0..<count { length = length * 256 + Int(bytes[offset]); offset += 1 }
                guard length >= 128 else { return nil }
            }
            guard length <= bytes.count - offset else { return nil }
            let range = offset..<(offset + length)
            offset += length
            return range
        }
        guard let outer = element(0x30), offset == bytes.count else { return nil }
        offset = outer.lowerBound
        guard let algorithm = element(0x30),
              Data(bytes[algorithm]) == Data([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]),
              let bits = element(0x03), offset == outer.upperBound,
              bits.count > 1, bytes[bits.lowerBound] == 0 else { return nil }
        return Data(bytes[(bits.lowerBound + 1)..<bits.upperBound])
    }
}

#endif
