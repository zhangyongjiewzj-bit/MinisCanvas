import Foundation
import CryptoKit
import CommonCrypto

/// The file-level protection requested for one export/import operation.
/// `.legacy` intentionally preserves the existing plaintext JSON contract.
public enum SyncSnapshotProtection: Sendable {
    case legacy
    case password(String)
}

public enum SyncSnapshotProtectionKind: Equatable, Sendable {
    case legacyPlaintext
    case passwordProtected
}

public enum SyncProtectionError: Error, Equatable, LocalizedError, Sendable {
    case protectionRequired
    case unsupportedEnvelope
    case unsupportedScheme
    case unsupportedVersion
    case invalidParameters
    case resourceLimit
    case randomSourceFailed
    case keyDerivationFailed
    case wrongPasswordOrCorrupt
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .protectionRequired:
            return "此备份受密码保护，请输入密码后重试。"
        case .unsupportedEnvelope, .unsupportedScheme, .unsupportedVersion:
            return "备份保护格式不受支持。"
        case .invalidParameters, .resourceLimit:
            return "备份保护参数无效或超出资源限制。"
        case .randomSourceFailed, .keyDerivationFailed:
            return "无法准备备份保护，请稍后重试。"
        case .wrongPasswordOrCorrupt:
            return "密码错误或备份已损坏。"
        case .cancelled:
            return "备份操作已取消。"
        }
    }
}

struct SyncProtectedEnvelope: Codable, Sendable {
    let format: String
    let containerVersion: Int
    let protection: SyncProtectedPayload
}

struct SyncProtectedPayload: Codable, Sendable {
    let scheme: String
    let schemeVersion: Int
    let iterations: UInt32
    let salt: Data
    let nonce: Data
    let aadVersion: Int
    let sealedPayload: Data
}

private struct SyncProtectionHeader: Codable {
    let format: String
    let containerVersion: Int
    let scheme: String
    let schemeVersion: Int
    let iterations: UInt32
    let salt: Data
    let nonce: Data
    let aadVersion: Int
}

enum SyncProtectionCodec {
    static let format = "minissync"
    static let scheme = "pbkdf2-hmac-sha256+aes-256-gcm"
    static let schemeVersion = 1
    static let aadVersion = 1
    static let minimumRounds: UInt32 = 600_000
    static let maximumRounds: UInt32 = 2_000_000
    static let calibrationMilliseconds: UInt32 = 250
    static let keyLength = 32
    static let saltLength = 16
    static let nonceLength = 12
    static let tagLength = 16
    static let maximumPasswordBytes = 1024
    static let maximumPayloadBytes = 64 * 1024 * 1024
    static let maximumProtectedFileBytes = 96 * 1024 * 1024

    static func protectionKind(for data: Data) throws -> SyncSnapshotProtectionKind {
        guard data.count <= maximumProtectedFileBytes else { throw SyncProtectionError.resourceLimit }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .legacyPlaintext
        }

        let hasProtectionMarker = object["format"] != nil
            || object["containerVersion"] != nil
            || object["protection"] != nil
        guard hasProtectionMarker else { return .legacyPlaintext }
        guard object["format"] as? String == format,
              object["containerVersion"] != nil,
              object["protection"] != nil else {
            throw SyncProtectionError.unsupportedEnvelope
        }
        return .passwordProtected
    }

    static func seal(_ plaintext: Data, password: String) throws -> Data {
        guard plaintext.count <= maximumPayloadBytes else { throw SyncProtectionError.resourceLimit }
        let passwordBytes = try passwordBytes(password)
        let salt = try randomData(count: saltLength)
        let nonceData = try randomData(count: nonceLength)
        let rounds = try calibratedRounds(passwordLength: passwordBytes.count)
        let key = try deriveKey(passwordBytes: passwordBytes, salt: salt, rounds: rounds)
        let header = SyncProtectionHeader(
            format: format,
            containerVersion: SyncManifest.protectedContainerVersion,
            scheme: scheme,
            schemeVersion: schemeVersion,
            iterations: rounds,
            salt: salt,
            nonce: nonceData,
            aadVersion: aadVersion
        )
        let aad = try canonicalData(header)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        let payload = SyncProtectedPayload(
            scheme: scheme,
            schemeVersion: schemeVersion,
            iterations: rounds,
            salt: salt,
            nonce: nonceData,
            aadVersion: aadVersion,
            sealedPayload: sealed.ciphertext + sealed.tag
        )
        let envelope = SyncProtectedEnvelope(
            format: format,
            containerVersion: SyncManifest.protectedContainerVersion,
            protection: payload
        )
        let data = try canonicalData(envelope)
        guard data.count <= maximumProtectedFileBytes else { throw SyncProtectionError.resourceLimit }
        return data
    }

    static func open(_ data: Data, password: String?) throws -> Data {
        switch try protectionKind(for: data) {
        case .legacyPlaintext:
            guard data.count <= maximumPayloadBytes else { throw SyncProtectionError.resourceLimit }
            return data
        case .passwordProtected:
            guard let password else { throw SyncProtectionError.protectionRequired }
            let envelope: SyncProtectedEnvelope
            do {
                envelope = try JSONDecoder().decode(SyncProtectedEnvelope.self, from: data)
            } catch {
                throw SyncProtectionError.unsupportedEnvelope
            }
            guard envelope.format == format,
                  envelope.containerVersion == SyncManifest.protectedContainerVersion,
                  envelope.protection.scheme == scheme,
                  envelope.protection.schemeVersion == schemeVersion,
                  envelope.protection.aadVersion == aadVersion,
                  envelope.protection.salt.count == saltLength,
                  envelope.protection.nonce.count == nonceLength,
                  envelope.protection.sealedPayload.count >= tagLength,
                  envelope.protection.iterations >= minimumRounds,
                  envelope.protection.iterations <= maximumRounds else {
                throw SyncProtectionError.invalidParameters
            }

            let passwordBytes = try passwordBytes(password)
            let key = try deriveKey(
                passwordBytes: passwordBytes,
                salt: envelope.protection.salt,
                rounds: envelope.protection.iterations
            )
            let header = SyncProtectionHeader(
                format: envelope.format,
                containerVersion: envelope.containerVersion,
                scheme: envelope.protection.scheme,
                schemeVersion: envelope.protection.schemeVersion,
                iterations: envelope.protection.iterations,
                salt: envelope.protection.salt,
                nonce: envelope.protection.nonce,
                aadVersion: envelope.protection.aadVersion
            )
            let aad = try canonicalData(header)
            let ciphertextEnd = envelope.protection.sealedPayload.count - tagLength
            let ciphertext = Data(envelope.protection.sealedPayload.prefix(ciphertextEnd))
            let tag = Data(envelope.protection.sealedPayload.suffix(tagLength))
            do {
                let nonce = try AES.GCM.Nonce(data: envelope.protection.nonce)
                let sealed = try AES.GCM.SealedBox(
                    nonce: nonce,
                    ciphertext: ciphertext,
                    tag: tag
                )
                let plaintext = try AES.GCM.open(sealed, using: key, authenticating: aad)
                guard plaintext.count <= maximumPayloadBytes else { throw SyncProtectionError.resourceLimit }
                return plaintext
            } catch let error as SyncProtectionError {
                throw error
            } catch {
                throw SyncProtectionError.wrongPasswordOrCorrupt
            }
        }
    }

    private static func passwordBytes(_ password: String) throws -> [UInt8] {
        let bytes = Array(password.utf8)
        guard password.unicodeScalars.count >= 12,
              !bytes.isEmpty,
              bytes.count <= maximumPasswordBytes else {
            throw SyncProtectionError.invalidParameters
        }
        return bytes
    }

    private static func calibratedRounds(passwordLength: Int) throws -> UInt32 {
        let calibrated = CCCalibratePBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordLength,
            saltLength,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            keyLength,
            calibrationMilliseconds
        )
        guard calibrated != UInt32.max else { throw SyncProtectionError.keyDerivationFailed }
        return min(max(calibrated, minimumRounds), maximumRounds)
    }

    private static func deriveKey(passwordBytes: [UInt8], salt: Data, rounds: UInt32) throws -> SymmetricKey {
        guard rounds >= minimumRounds,
              rounds <= maximumRounds,
              salt.count == saltLength else {
            throw SyncProtectionError.invalidParameters
        }
        var derived = Data(count: keyLength)
        let status = derived.withUnsafeMutableBytes { derivedBuffer in
            salt.withUnsafeBytes { saltBuffer in
                passwordBytes.withUnsafeBytes { passwordBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.bindMemory(to: CChar.self).baseAddress,
                        passwordBuffer.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        saltBuffer.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        rounds,
                        derivedBuffer.bindMemory(to: UInt8.self).baseAddress,
                        derivedBuffer.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw SyncProtectionError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }

    private static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            CCRandomGenerateBytes(buffer.baseAddress, buffer.count)
        }
        guard status == kCCSuccess else { throw SyncProtectionError.randomSourceFailed }
        return data
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
