import CryptoKit
import Foundation
import Security

struct VMGuestAgentEnrollment: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let machineID: String
    let token: Data
    let port: UInt32

    init(machineID: String, token: Data) {
        schemaVersion = Self.currentSchemaVersion
        self.machineID = machineID
        self.token = token
        port = VMGuestAgentProtocol.port
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              token.count == 32,
              !machineID.isEmpty,
              port == VMGuestAgentProtocol.port else {
            throw VMGuestAgentAuthenticationError.invalidToken
        }
    }
}

enum VMGuestAgentEnrollmentStore {
    private static let service = "com.everettjf.easyvm.guest-agent"

    static func machineID(machineIdentifierData: Data) -> String {
        SHA256.hash(data: machineIdentifierData).map { String(format: "%02x", $0) }.joined()
    }

    static func loadOrCreate(machineIdentifierData: Data) -> VMOSResult<VMGuestAgentEnrollment, String> {
        let machineID = machineID(machineIdentifierData: machineIdentifierData)
        switch load(machineID: machineID) {
        case .failure(let error): return .failure(error)
        case .success(let existing?): return .success(existing)
        case .success(nil):
            let enrollment = VMGuestAgentEnrollment(
                machineID: machineID,
                token: VMGuestAgentAuthenticator.generateToken()
            )
            switch save(enrollment) {
            case .success: return .success(enrollment)
            case .failure(let error): return .failure(error)
            }
        }
    }

    static func load(machineIdentifierData: Data) -> VMOSResult<VMGuestAgentEnrollment?, String> {
        load(machineID: machineID(machineIdentifierData: machineIdentifierData))
    }

    static func save(_ enrollment: VMGuestAgentEnrollment) -> VMOSResultVoid {
        do {
            try enrollment.validate()
            let data = try JSONEncoder().encode(enrollment)
            let query = baseQuery(machineID: enrollment.machineID)
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
            if update == errSecSuccess { return .success }
            guard update == errSecItemNotFound else { return .failure(message(for: update)) }
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(addition as CFDictionary, nil)
            return status == errSecSuccess ? .success : .failure(message(for: status))
        } catch {
            return .failure("Could not save guest-agent enrollment: \(error.localizedDescription)")
        }
    }

    static func load(machineID: String) -> VMOSResult<VMGuestAgentEnrollment?, String> {
        var query = baseQuery(machineID: machineID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return .success(nil) }
        guard status == errSecSuccess, let data = value as? Data else { return .failure(message(for: status)) }
        do {
            let enrollment = try JSONDecoder().decode(VMGuestAgentEnrollment.self, from: data)
            try enrollment.validate()
            guard enrollment.machineID == machineID else { throw VMGuestAgentAuthenticationError.invalidMachine }
            return .success(enrollment)
        } catch {
            return .failure("The guest-agent enrollment in Keychain is invalid: \(error.localizedDescription)")
        }
    }

    static func delete(machineIdentifierData: Data) -> VMOSResultVoid {
        let status = SecItemDelete(baseQuery(machineID: machineID(machineIdentifierData: machineIdentifierData)) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound ? .success : .failure(message(for: status))
    }

    static func installationConfiguration(_ enrollment: VMGuestAgentEnrollment) throws -> Data {
        try enrollment.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(enrollment)
    }

    static func decodeInstallationConfiguration(_ data: Data, machineIdentifierData: Data) throws -> VMGuestAgentEnrollment {
        let enrollment = try JSONDecoder().decode(VMGuestAgentEnrollment.self, from: data)
        try enrollment.validate()
        guard enrollment.machineID == machineID(machineIdentifierData: machineIdentifierData) else {
            throw VMGuestAgentAuthenticationError.invalidMachine
        }
        return enrollment
    }

    private static func baseQuery(machineID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: machineID,
        ]
    }

    private static func message(for status: OSStatus) -> String {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Could not access the guest-agent token in Keychain: \(detail)"
    }
}
