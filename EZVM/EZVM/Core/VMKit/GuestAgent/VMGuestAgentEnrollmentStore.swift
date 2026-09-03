import CryptoKit
import Foundation

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
    static let sharedDirectoryTag = "ezvm-agent"
    static let sharedConfigurationFileName = "config.json"
    static let inputReadinessKeyPrefix = "guestAgent.inputReady."

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

    static func loadOrCreate(
        machineIdentifierData: Data,
        directoryURL: URL
    ) -> VMOSResult<VMGuestAgentEnrollment, String> {
        let machineID = machineID(machineIdentifierData: machineIdentifierData)
        let configurationURL = directoryURL.appending(
            path: sharedConfigurationFileName,
            directoryHint: .notDirectory
        )
        do {
            if FileManager.default.fileExists(atPath: configurationURL.path) {
                let enrollment = try JSONDecoder().decode(
                    VMGuestAgentEnrollment.self,
                    from: Data(contentsOf: configurationURL, options: [.mappedIfSafe])
                )
                try enrollment.validate()
                guard enrollment.machineID == machineID else {
                    throw VMGuestAgentAuthenticationError.invalidMachine
                }
                return .success(enrollment)
            }
            let enrollment = VMGuestAgentEnrollment(
                machineID: machineID,
                token: VMGuestAgentAuthenticator.generateToken()
            )
            switch writeSharedConfiguration(enrollment, directoryURL: directoryURL) {
            case .success: return .success(enrollment)
            case .failure(let error): return .failure(error)
            }
        } catch {
            return .failure("The guest-agent enrollment file is invalid: \(error.localizedDescription)")
        }
    }

    static func load(machineIdentifierData: Data) -> VMOSResult<VMGuestAgentEnrollment?, String> {
        load(machineID: machineID(machineIdentifierData: machineIdentifierData))
    }

    static func save(_ enrollment: VMGuestAgentEnrollment) -> VMOSResultVoid {
        do {
            try enrollment.validate()
            let data = try JSONEncoder().encode(enrollment)
            let directory = enrollmentDirectoryURL()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path(percentEncoded: false)
            )
            let destination = enrollmentURL(machineID: enrollment.machineID)
            try data.write(to: destination, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path(percentEncoded: false)
            )
            return .success
        } catch {
            return .failure("Could not save guest-agent enrollment: \(error.localizedDescription)")
        }
    }

    static func load(machineID: String) -> VMOSResult<VMGuestAgentEnrollment?, String> {
        do {
            let url = enrollmentURL(machineID: machineID)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                return .success(nil)
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let enrollment = try JSONDecoder().decode(VMGuestAgentEnrollment.self, from: data)
            try enrollment.validate()
            guard enrollment.machineID == machineID else { throw VMGuestAgentAuthenticationError.invalidMachine }
            return .success(enrollment)
        } catch {
            return .failure("The guest-agent enrollment file is invalid: \(error.localizedDescription)")
        }
    }

    static func delete(machineIdentifierData: Data) -> VMOSResultVoid {
        let url = enrollmentURL(machineID: machineID(machineIdentifierData: machineIdentifierData))
        do {
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
            UserDefaults.standard.removeObject(
                forKey: inputReadinessKey(machineIdentifierData: machineIdentifierData)
            )
            return .success
        } catch {
            return .failure("Could not delete guest-agent enrollment: \(error.localizedDescription)")
        }
    }

    static func isInputReady(
        machineIdentifierData: Data,
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: inputReadinessKey(machineIdentifierData: machineIdentifierData))
    }

    static func markInputReady(
        machineIdentifierData: Data,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(true, forKey: inputReadinessKey(machineIdentifierData: machineIdentifierData))
    }

    static func inputReadinessKey(machineIdentifierData: Data) -> String {
        inputReadinessKeyPrefix + machineID(machineIdentifierData: machineIdentifierData)
    }

    static func installationConfiguration(_ enrollment: VMGuestAgentEnrollment) throws -> Data {
        try enrollment.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(enrollment)
    }

    static func prepareSharedConfiguration(
        machineIdentifierData: Data,
        directoryURL: URL
    ) -> VMOSResult<URL, String> {
        switch loadOrCreate(machineIdentifierData: machineIdentifierData) {
        case .failure(let error):
            return .failure(error)
        case .success(let enrollment):
            return writeSharedConfiguration(enrollment, directoryURL: directoryURL)
        }
    }

    static func writeSharedConfiguration(
        _ enrollment: VMGuestAgentEnrollment,
        directoryURL: URL
    ) -> VMOSResult<URL, String> {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path(percentEncoded: false)
            )
            let configurationURL = directoryURL.appending(
                path: sharedConfigurationFileName,
                directoryHint: .notDirectory
            )
            try installationConfiguration(enrollment).write(to: configurationURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configurationURL.path(percentEncoded: false)
            )
            return .success(configurationURL)
        } catch {
            return .failure("Could not prepare guest-agent enrollment share: \(error.localizedDescription)")
        }
    }

    static func decodeInstallationConfiguration(_ data: Data, machineIdentifierData: Data) throws -> VMGuestAgentEnrollment {
        let enrollment = try JSONDecoder().decode(VMGuestAgentEnrollment.self, from: data)
        try enrollment.validate()
        guard enrollment.machineID == machineID(machineIdentifierData: machineIdentifierData) else {
            throw VMGuestAgentAuthenticationError.invalidMachine
        }
        return enrollment
    }

    private static func enrollmentDirectoryURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "EZVM/GuestAgentEnrollments", directoryHint: .isDirectory)
    }

    private static func enrollmentURL(machineID: String) -> URL {
        enrollmentDirectoryURL().appending(path: "\(machineID).json", directoryHint: .notDirectory)
    }
}
