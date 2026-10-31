#if canImport(CryptoKit) && canImport(Security)
import CryptoKit
import Foundation
import Security
import XCTest
#if !KESTREL_CRX_TESTS
@testable import KestrelWebKit
#endif

final class CRXPackageTests: XCTestCase {
    // Ephemeral keys are generated in memory. No private signing key is saved.
    private struct Signer {
        let publicKey: Data
        let field: UInt64
        let sign: (Data) throws -> Data
    }

    private func ecSigner() -> Signer {
        let key = P256.Signing.PrivateKey()
        return Signer(publicKey: key.publicKey.derRepresentation, field: 3,
                      sign: { try key.signature(for: $0).derRepresentation })
    }

    private func rsaSigner() throws -> Signer {
        let key = try XCTUnwrap(SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048
        ] as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let pkcs1 = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        let algorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
        let spki = der(0x30, algorithm + der(0x03, Data([0]) + pkcs1))
        return Signer(publicKey: spki, field: 2, sign: { message in
            try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil)) as Data
        })
    }

    private let zip = Data([0x50, 0x4b, 0x03, 0x04, 1, 2, 3, 4])

    private func package(_ signer: Signer, id: Data? = nil, archive: Data? = nil,
                         additionalSigner: Signer? = nil, extraHeader: Data = Data()) throws -> Data {
        let identity = id ?? Data(SHA256.hash(data: signer.publicKey).prefix(16))
        let signed = field(1, identity)
        let archive = archive ?? zip
        let message = Data("CRX3 SignedData\0".utf8) + le32(signed.count) + signed + archive
        func proof(_ signer: Signer) throws -> Data {
            field(signer.field, field(1, signer.publicKey) + field(2, try signer.sign(message)))
        }
        var header = try proof(signer) + field(10000, signed) + extraHeader
        if let additionalSigner { header += try proof(additionalSigner) }
        return Data("Cr24".utf8) + le32(3) + le32(header.count) + header + archive
    }

    func testECDSASignatureAndManifestIdentity() throws {
        let signer = ecSigner()
        let verified = try CRXPackage(data: package(signer))
        XCTAssertEqual(verified.archive, zip)
        XCTAssertEqual(verified.publicKey, signer.publicKey)
        let hash = SHA256.hash(data: signer.publicKey)
        let expected = hash.prefix(16).map { String(format: "%02x", $0) }.joined()
            .map { String(UnicodeScalar(97 + Int(String($0), radix: 16)!)!) }.joined()
        XCTAssertEqual(verified.extensionID, expected)
        let manifest = try verified.manifestPreservingIdentity(Data(#"{"manifest_version":3,"name":"Fixture","version":"1"}"#.utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        XCTAssertEqual(object["key"] as? String, signer.publicKey.base64EncodedString())
        XCTAssertEqual(object["name"] as? String, "Fixture")
        XCTAssertNoThrow(try verified.manifestPreservingIdentity(manifest))
    }

    func testRSASignatureAndMultipleProofs() throws {
        let signer = try rsaSigner()
        let verified = try CRXPackage(data: package(signer, additionalSigner: ecSigner()))
        XCTAssertEqual(verified.publicKey, signer.publicKey)
    }

    func testTamperedArchiveAndSignatureAreRejected() throws {
        let original = try package(ecSigner())
        var tampered = original
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try CRXPackage(data: tampered))
        // Change a byte in the first proof's signature, preserving its key.
        let signer = ecSigner()
        let signed = field(1, Data(SHA256.hash(data: signer.publicKey).prefix(16)))
        let message = Data("CRX3 SignedData\0".utf8) + le32(signed.count) + signed + zip
        var signature = try signer.sign(message)
        signature[signature.count - 1] ^= 1
        let header = field(3, field(1, signer.publicKey) + field(2, signature)) + field(10000, signed)
        XCTAssertThrowsError(try CRXPackage(data: Data("Cr24".utf8) + le32(3) + le32(header.count) + header + zip))
    }

    func testSignedIdentityMismatchAndConflictingManifestAreRejected() throws {
        let signer = ecSigner()
        XCTAssertThrowsError(try CRXPackage(data: package(signer, id: Data(repeating: 0, count: 16))))
        let verified = try CRXPackage(data: package(signer))
        for manifest in [#"{"key":"YWJj"}"#, #"{"key":4}"#, "[]"] {
            XCTAssertThrowsError(try verified.manifestPreservingIdentity(Data(manifest.utf8)))
        }
    }

    func testMalformedHeadersAndLegacyFormatsAreRejected() throws {
        let valid = try package(ecSigner())
        for count in 0..<12 { XCTAssertThrowsError(try CRXPackage(data: Data(valid.prefix(count)))) }
        for version in [2, 4] {
            XCTAssertThrowsError(try CRXPackage(data: Data("Cr24".utf8) + le32(version) + valid.dropFirst(8)))
        }
        for size in [0, 1_000_001, Int(UInt32.max)] {
            XCTAssertThrowsError(try CRXPackage(data: Data("Cr24".utf8) + le32(3) + le32(size) + zip))
        }
        for header in [Data([0]), Data(repeating: 255, count: 12), Data([0x12, 0xff, 0xff, 0x7f]), field(10000, Data([0x0b]))] {
            XCTAssertThrowsError(try CRXPackage(data: Data("Cr24".utf8) + le32(3) + le32(header.count) + header + zip))
        }
        XCTAssertThrowsError(try CRXPackage(data: zip))
        XCTAssertThrowsError(try CRXPackage(data: package(ecSigner(), archive: Data("not a zip".utf8))))
    }

    func testDuplicateAndMissingSigningFieldsAreRejected() throws {
        let signer = ecSigner()
        XCTAssertThrowsError(try CRXPackage(data: package(signer, extraHeader: field(10000, field(1, Data(repeating: 0, count: 16))))))
        let header = field(10000, field(1, Data(repeating: 0, count: 16)))
        XCTAssertThrowsError(try CRXPackage(data: Data("Cr24".utf8) + le32(3) + le32(header.count) + header + zip))
        XCTAssertThrowsError(try CRXPackage(data: package(signer, extraHeader: field(3, field(1, signer.publicKey)))))
    }

    private func le32(_ value: Int) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: UInt32(value) >> ($0 * 8)) })
    }
    private func varint(_ value: UInt64) -> Data {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            let byte = UInt8(value & 127); value >>= 7
            bytes.append(byte | (value > 0 ? 128 : 0))
        } while value > 0
        return Data(bytes)
    }
    private func field(_ number: UInt64, _ bytes: Data) -> Data {
        varint(number << 3 | 2) + varint(UInt64(bytes.count)) + bytes
    }
    private func der(_ tag: UInt8, _ bytes: Data) -> Data {
        let length = bytes.count < 128 ? Data([UInt8(bytes.count)])
            : Data([0x82, UInt8(bytes.count >> 8), UInt8(bytes.count & 255)])
        return Data([tag]) + length + bytes
    }

}
#endif
