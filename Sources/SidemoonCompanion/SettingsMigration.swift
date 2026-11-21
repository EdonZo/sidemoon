import Foundation

/// Saved settings live in the bundle identifier's defaults domain, which changed with the rename from Tagalong.
/// On the first launch under the new identifier, the settings saved by the old build are copied over once.
public enum SettingsMigration {
    /// Copies the app's saved keys from `legacy` into `current` when `current` holds none of them yet.
    /// Returns the keys copied (empty when there was nothing to do). The legacy domain is left as it was.
    @discardableResult
    public static func migrate(from legacy: UserDefaults, to current: UserDefaults,
                               keys: [String] = CompanionConstants.Defaults.savedKeys) -> [String] {
        guard !keys.contains(where: { current.object(forKey: $0) != nil }) else { return [] }
        var copied: [String] = []
        for key in keys {
            guard let value = legacy.object(forKey: key) else { continue }
            current.set(value, forKey: key)
            copied.append(key)
        }
        return copied
    }

    /// The app's own migration: only when running as the renamed bundle, from the legacy bundle's domain.
    @discardableResult
    public static func migrateStandardDefaults(bundleIdentifier: String?) -> [String] {
        guard bundleIdentifier == CompanionConstants.App.bundleIdentifier,
              let legacy = UserDefaults(suiteName: CompanionConstants.App.legacyBundleIdentifier)
        else { return [] }
        return migrate(from: legacy, to: .standard)
    }
}
