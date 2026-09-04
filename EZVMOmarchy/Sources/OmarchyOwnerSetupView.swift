import EZVMCore
import SwiftUI

struct OmarchyOwnerSetupForm: Equatable {
    struct KeyboardLayout: Identifiable, Equatable {
        let label: String
        let code: String
        var id: String { label }
    }

    var username = "omarchy"
    var password = ""
    var passwordConfirmation = ""
    var keyboard = "us"
    var fullName = ""
    var emailAddress = ""
    var hostname = "omarchy"
    var timezone = TimeZone.current.identifier

    static let reservedUsernames: Set<String> = [
        "root", "bin", "daemon", "mail", "ftp", "http", "nobody", "dbus",
        "systemd-coredump", "systemd-network", "systemd-oom", "systemd-journal-remote",
        "systemd-resolve", "systemd-timesync", "tss", "uuidd", "alpm", "git", "avahi",
        "cups", "cups-browsed", "lp", "_talkd", "polkitd", "rtkit", "qemu", "brltty",
        "gluster", "rpc", "libvirt-qemu", "pcscd", "nvidia-persistenced", "sddm",
    ]

    static let keyboardLayouts: [KeyboardLayout] = [
        .init(label: "English (US)", code: "us"), .init(label: "English (UK)", code: "uk"),
        .init(label: "English (US, Dvorak)", code: "dvorak"), .init(label: "English (US, Colemak)", code: "colemak"),
        .init(label: "Azerbaijani", code: "azerty"), .init(label: "Belarusian", code: "by"), .init(label: "Belgian", code: "be-latin1"),
        .init(label: "Bulgarian", code: "bg-cp1251"), .init(label: "Croatian", code: "croat"), .init(label: "Czech", code: "cz"),
        .init(label: "Danish", code: "dk-latin1"), .init(label: "Dutch", code: "nl"), .init(label: "Estonian", code: "et"),
        .init(label: "Finnish", code: "fi"), .init(label: "French", code: "fr"), .init(label: "French (Canada)", code: "cf"),
        .init(label: "French (Switzerland)", code: "fr_CH"), .init(label: "Georgian", code: "ge"), .init(label: "German", code: "de"),
        .init(label: "German (Switzerland)", code: "de_CH-latin1"), .init(label: "Greek", code: "gr"), .init(label: "Hebrew", code: "il"),
        .init(label: "Hungarian", code: "hu"), .init(label: "Icelandic", code: "is-latin1"), .init(label: "Irish", code: "ie"),
        .init(label: "Italian", code: "it"), .init(label: "Japanese", code: "jp106"), .init(label: "Kazakh", code: "kazakh"),
        .init(label: "Kyrgyz", code: "kyrgyz"), .init(label: "Lao", code: "la-latin1"), .init(label: "Latvian", code: "lv"),
        .init(label: "Lithuanian", code: "lt"), .init(label: "Macedonian", code: "mk-utf"), .init(label: "Norwegian", code: "no-latin1"),
        .init(label: "Polish", code: "pl"), .init(label: "Portuguese", code: "pt-latin1"),
        .init(label: "Portuguese (Brazil)", code: "br-abnt2"), .init(label: "Romanian", code: "ro"), .init(label: "Russian", code: "ru"),
        .init(label: "Serbian", code: "sr-latin"), .init(label: "Slovak", code: "sk-qwertz"), .init(label: "Slovenian", code: "slovene"),
        .init(label: "Spanish", code: "es"), .init(label: "Spanish (Latin American)", code: "la-latin1"),
        .init(label: "Swedish", code: "sv-latin1"), .init(label: "Tajik", code: "tj_alt-UTF8"), .init(label: "Turkish", code: "trq"),
        .init(label: "Ukrainian", code: "ua"),
    ]

    mutating func clearSecrets() {
        password = ""
        passwordConfirmation = ""
    }

    func validatedRequest() throws -> VMOmarchyOwnerProvisioningRequest {
        guard Self.validUsername(username), !Self.reservedUsernames.contains(username) else {
            throw ValidationError.invalidUsername
        }
        guard !password.isEmpty, password.utf8.count <= 128, !password.hasControlCharacters else {
            throw ValidationError.invalidPassword
        }
        guard password == passwordConfirmation else { throw ValidationError.passwordsDoNotMatch }
        guard Self.keyboardLayouts.contains(where: { $0.code == keyboard }) else {
            throw ValidationError.invalidKeyboard
        }
        guard fullName.utf8.count <= 128, emailAddress.utf8.count <= 254,
              !fullName.hasControlCharacters, !emailAddress.hasControlCharacters else {
            throw ValidationError.invalidIdentity
        }
        guard Self.validHostname(hostname) else { throw ValidationError.invalidHostname }
        guard TimeZone(identifier: timezone) != nil else { throw ValidationError.invalidTimezone }
        return VMOmarchyOwnerProvisioningRequest(
            username: username,
            password: password,
            keyboard: keyboard,
            fullName: fullName,
            emailAddress: emailAddress,
            hostname: hostname,
            timezone: timezone
        )
    }

    private static func validUsername(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 32,
              asciiLowercase(bytes[0]) || bytes[0] == 0x5f else { return false }
        for (index, byte) in bytes.dropFirst().enumerated() {
            if byte == 0x24 { return index == bytes.count - 2 }
            guard asciiLowercase(byte) || asciiDigit(byte) || byte == 0x5f || byte == 0x2d else {
                return false
            }
        }
        return true
    }

    private static func validHostname(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...63).contains(bytes.count), let first = bytes.first, let last = bytes.last,
              asciiAlphanumeric(first), asciiAlphanumeric(last) else { return false }
        return bytes.allSatisfy { asciiAlphanumeric($0) || $0 == 0x2d }
    }

    private static func asciiLowercase(_ byte: UInt8) -> Bool { (0x61...0x7a).contains(byte) }
    private static func asciiDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
    private static func asciiAlphanumeric(_ byte: UInt8) -> Bool {
        asciiLowercase(byte) || asciiDigit(byte) || (0x41...0x5a).contains(byte)
    }

    enum ValidationError: LocalizedError, Equatable {
        case invalidUsername
        case invalidPassword
        case passwordsDoNotMatch
        case invalidKeyboard
        case invalidIdentity
        case invalidHostname
        case invalidTimezone

        var errorDescription: String? {
            switch self {
            case .invalidUsername: "Choose a lowercase username that is not reserved by the system."
            case .invalidPassword: "Enter a password of at most 128 bytes without control characters."
            case .passwordsDoNotMatch: "The passwords do not match."
            case .invalidKeyboard: "Choose a supported keyboard layout."
            case .invalidIdentity: "The optional name or email is too long or contains unsupported characters."
            case .invalidHostname: "The hostname must be 1–63 letters, digits, or dashes and cannot begin or end with a dash."
            case .invalidTimezone: "Choose a valid time zone."
            }
        }
    }
}

private extension String {
    var hasControlCharacters: Bool {
        unicodeScalars.contains {
            $0.value < 0x20 || (0x7f...0x9f).contains($0.value)
        }
    }
}

struct OmarchyOwnerProvisioningSubmission: Equatable, Identifiable {
    let id: UUID
    let request: VMOmarchyOwnerProvisioningRequest

    init(id: UUID = UUID(), request: VMOmarchyOwnerProvisioningRequest) {
        self.id = id
        self.request = request
    }
}

enum OmarchyOwnerSetupPhase: Equatable {
    case editing
    case submitting
    case finishing
    case failed(String)
}

struct OmarchyOwnerSetupView: View {
    @Binding var form: OmarchyOwnerSetupForm
    let phase: OmarchyOwnerSetupPhase
    let submit: () -> Void
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case username, password, confirmation, fullName, email, hostname, timezone }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Set up your Omarchy owner")
                    .font(.title.weight(.semibold))
                Text("These details are sent once through the authenticated local VM channel and are not saved by EZVM Omarchy.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }

            Form {
                Section("Account") {
                    TextField("Username", text: $form.username)
                        .focused($focusedField, equals: .username)
                        .textContentType(.username)
                    SecureField("Password", text: $form.password)
                        .focused($focusedField, equals: .password)
                        .textContentType(.newPassword)
                    SecureField("Confirm password", text: $form.passwordConfirmation)
                        .focused($focusedField, equals: .confirmation)
                        .textContentType(.newPassword)
                    TextField("Full name (optional)", text: $form.fullName)
                        .focused($focusedField, equals: .fullName)
                    TextField("Email for Git (optional)", text: $form.emailAddress)
                        .focused($focusedField, equals: .email)
                        .textContentType(.emailAddress)
                }
                Section("System") {
                    Picker("Keyboard", selection: $form.keyboard) {
                        ForEach(OmarchyOwnerSetupForm.keyboardLayouts) { layout in
                            Text(layout.label).tag(layout.code)
                        }
                    }
                    TextField("Hostname", text: $form.hostname)
                        .focused($focusedField, equals: .hostname)
                    TextField("Time zone", text: $form.timezone)
                        .focused($focusedField, equals: .timezone)
                }
            }
            .formStyle(.grouped)
            .frame(width: 600, height: 365)

            if case .failed(let message) = phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
                    .accessibilityLabel("Setup error: \(message)")
            }

            switch phase {
            case .editing, .failed:
                Button("Create Omarchy Owner", action: submit)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            case .submitting:
                ProgressView("Sending owner setup securely…")
            case .finishing:
                ProgressView("Omarchy is creating your workspace…")
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .defaultFocus($focusedField, .username)
    }
}
