import Foundation
import SwiftUI

enum AppTheme: String, CaseIterable {
    case light = "light"
    case dark = "dark"
    case system = "system"

    var label: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

/// Persists user profile and preferences via UserDefaults.
/// Shared across the app as an ObservableObject.
class UserSettings: ObservableObject {
    static let shared = UserSettings()

    private let firstNameKey           = "mtst_first_name"
    private let lastNameKey            = "mtst_last_name"
    private let themeKey               = "mtst_theme"
    private let showCopyAllKey         = "mtst_show_copy_all"
    private let quickCheckModeKey      = "mtst_quick_check_mode"
    private let mtCompleteModeKey      = "mtst_mt_complete_mode"
    private let backOfficeUsernameKey  = "mtst_bo_username"
    private let hasBackOfficeCredsKey  = "mtst_bo_has_creds"
    private let nolanRyanVolumeKey     = "mtst_nr_volume"
    private let useKeychainKey         = "mtst_use_keychain"
    private let autoFadeCutsKey        = "mtst_auto_fade_cuts"

    @Published var firstName: String {
        didSet { UserDefaults.standard.set(firstName, forKey: firstNameKey) }
    }

    @Published var lastName: String {
        didSet { UserDefaults.standard.set(lastName, forKey: lastNameKey) }
    }

    @Published var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: themeKey) }
    }

    @Published var showCopyAll: Bool {
        didSet { UserDefaults.standard.set(showCopyAll, forKey: showCopyAllKey) }
    }

    @Published var quickCheckMode: Bool {
        didSet { UserDefaults.standard.set(quickCheckMode, forKey: quickCheckModeKey) }
    }

    @Published var mtCompleteMode: Bool {
        didSet { UserDefaults.standard.set(mtCompleteMode, forKey: mtCompleteModeKey) }
    }

    /// BackOffice web login username (password stored in Keychain via CredentialStore).
    @Published var backOfficeUsername: String {
        didSet { UserDefaults.standard.set(backOfficeUsername, forKey: backOfficeUsernameKey) }
    }

    /// True when BackOffice credentials have been saved (username + Keychain password present).
    @Published var hasBackOfficeCreds: Bool {
        didSet { UserDefaults.standard.set(hasBackOfficeCreds, forKey: hasBackOfficeCredsKey) }
    }

    /// When true, passwords are stored in the system Keychain (default).
    /// When false, passwords are stored in UserDefaults (unencrypted — legacy only).
    @Published var useKeychain: Bool {
        didSet { UserDefaults.standard.set(useKeychain, forKey: useKeychainKey) }
    }

    /// When true, a 10ms fade-in is applied to all audio cuts in the Edit tab (default: true).
    @Published var autoFadeCuts: Bool {
        didSet { UserDefaults.standard.set(autoFadeCuts, forKey: autoFadeCutsKey) }
    }

    /// The Finder volume name for the Nolan Ryan SMB share.
    /// This is the share name as it appears in /Volumes/ after mounting (default: "Pitching").
    /// The SMB server hostname is always "nolanryan" — this is separate from the server name.
    @Published var nolanRyanVolumeName: String {
        didSet { UserDefaults.standard.set(nolanRyanVolumeName, forKey: nolanRyanVolumeKey) }
    }

    var isLoggedIn: Bool {
        !firstName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !lastName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var fullName: String {
        "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
    }

    private init() {
        self.firstName = UserDefaults.standard.string(forKey: firstNameKey) ?? ""
        self.lastName  = UserDefaults.standard.string(forKey: lastNameKey) ?? ""
        let raw = UserDefaults.standard.string(forKey: themeKey) ?? "system"
        self.theme = AppTheme(rawValue: raw) ?? .system
        self.showCopyAll    = UserDefaults.standard.object(forKey: showCopyAllKey)    as? Bool ?? false
        self.quickCheckMode      = UserDefaults.standard.object(forKey: quickCheckModeKey)      as? Bool ?? false
        self.mtCompleteMode      = UserDefaults.standard.object(forKey: mtCompleteModeKey)      as? Bool ?? false
        self.backOfficeUsername  = UserDefaults.standard.string(forKey: backOfficeUsernameKey)  ?? ""
        self.hasBackOfficeCreds  = UserDefaults.standard.object(forKey: hasBackOfficeCredsKey)  as? Bool ?? false
        self.useKeychain         = UserDefaults.standard.object(forKey: useKeychainKey)         as? Bool ?? true
        self.autoFadeCuts        = UserDefaults.standard.object(forKey: autoFadeCutsKey)        as? Bool ?? true
        // Migrate old default "nolanryan" (server hostname) → "Pitching" (share/volume name).
        let storedVolume = UserDefaults.standard.string(forKey: nolanRyanVolumeKey) ?? "nolanryan"
        self.nolanRyanVolumeName = storedVolume == "nolanryan" ? "Pitching" : storedVolume
    }
}
