import Foundation
import SidemoonCompanion

enum InfoPlist {
    static var dictionary: [String: Any] {
        let app = CompanionConstants.App.self
        var plist: [String: Any] = [
            "CFBundleIdentifier": app.bundleIdentifier,
            "CFBundleName": app.name,
            "CFBundleDisplayName": app.name,
            "CFBundleExecutable": app.executableName,
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": app.iconFileName,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": app.version,
            "CFBundleVersion": app.build,
            "LSMinimumSystemVersion": app.minimumSystemVersion,
            // No Dock icon and no menu bar: the companion panel is the whole UI.
            "LSUIElement": true,
            "NSHighResolutionCapable": true,
            // Where scripts/build-app.sh puts the `sidemoon` CLI; the setup points the hooks and the channel at it.
            app.helperPlistKey: app.helperPathInBundle,
        ]
        // Sparkle's keys only once there is a public key to verify updates with.
        let updates = CompanionConstants.Updates.self
        if updates.isConfigured {
            plist[updates.feedURLPlistKey] = updates.feedURL
            plist[updates.publicEDKeyPlistKey] = updates.publicEDKey
            plist[updates.enableAutomaticChecksPlistKey] = updates.enableAutomaticChecks
        }
        return plist
    }

    static func xml() -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)) ?? Data()
    }
}
