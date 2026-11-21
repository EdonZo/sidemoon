import AppKit
import SidemoonCompanion

// `--print-info-plist` lets scripts/build-app.sh take every bundle value from CompanionConstants.App.
if CommandLine.arguments.contains(CompanionConstants.App.printInfoPlistFlag) {
    FileHandle.standardOutput.write(InfoPlist.xml())
    exit(0)
}

let application = NSApplication.shared

// `--render-preview <directory>` writes design preview images and exits.
if let flag = CommandLine.arguments.firstIndex(of: CompanionConstants.App.renderPreviewFlag),
   flag + 1 < CommandLine.arguments.count {
    Preview.render(to: CommandLine.arguments[flag + 1])
    exit(0)
}

// `--render-icon <directory> [--variant a|b|c]` writes the app icon concepts, contact sheet and AppIcon.icns, and exits.
if let flag = CommandLine.arguments.firstIndex(of: CompanionConstants.App.renderIconFlag),
   flag + 1 < CommandLine.arguments.count {
    AppIcon.render(to: CommandLine.arguments[flag + 1], arguments: CommandLine.arguments)
    exit(0)
}

// Before anything reads the saved settings: carry them over from the pre-rename (Tagalong) build once.
SettingsMigration.migrateStandardDefaults(bundleIdentifier: Bundle.main.bundleIdentifier)

let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
