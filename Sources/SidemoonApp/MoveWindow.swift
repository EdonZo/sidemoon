import AppKit
import SwiftUI
import SidemoonCompanion

/// The real copy into Applications and the relaunch from there.
struct SystemAppMover: AppMover {
    func isWritable(_ folder: String) -> Bool {
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        if fm.fileExists(atPath: folder, isDirectory: &isDirectory) { return isDirectory.boolValue && fm.isWritableFile(atPath: folder) }
        // ~/Applications may not exist yet; it can be made when the home folder can be written to.
        return fm.isWritableFile(atPath: (folder as NSString).deletingLastPathComponent)
    }

    /// Copies next to the destination first and swaps it in only once the copy is whole, so a failed copy never
    /// leaves the older Sidemoon half replaced.
    func copy(bundle: String, to destination: String) throws -> String {
        let fm = FileManager.default
        let folder = (destination as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let staging = (folder as NSString).appendingPathComponent(".\(UUID().uuidString)-\((destination as NSString).lastPathComponent)")
        try fm.copyItem(atPath: bundle, toPath: staging)
        removeQuarantine(staging)
        if fm.fileExists(atPath: destination) {
            _ = try fm.replaceItemAt(URL(fileURLWithPath: destination), withItemAt: URL(fileURLWithPath: staging))
        } else {
            try fm.moveItem(atPath: staging, toPath: destination)
        }
        return destination
    }

    /// A downloaded copy carries the quarantine mark; left on the copy in Applications, macOS would run it from a
    /// temporary copy again. This copy has already been checked by macOS when it was first opened.
    private func removeQuarantine(_ path: String) {
        let name = CompanionConstants.App.quarantineAttribute
        removexattr(path, name, XATTR_NOFOLLOW)
        guard let items = FileManager.default.enumerator(atPath: path) else { return }
        for case let item as String in items {
            removexattr((path as NSString).appendingPathComponent(item), name, XATTR_NOFOLLOW)
        }
    }

    func relaunch(at path: String) { BundleRelauncher(target: path).relaunch() }
}

/// A small window, before Setup, offering to move Sidemoon into the Applications folder.
@MainActor
final class MoveWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let mover: AppMover
    private let bundlePath: String
    private let home: String
    /// Runs once the window is done with and Sidemoon is staying where it is (Not now, or a failed move).
    private let onStay: () -> Void
    private var stayed = false
    private let state = MoveState()

    init(mover: AppMover = SystemAppMover(), bundlePath: String = Bundle.main.bundlePath,
         home: String = FileManager.default.homeDirectoryForCurrentUser.path, onStay: @escaping () -> Void) {
        self.mover = mover
        self.bundlePath = bundlePath
        self.home = home
        self.onStay = onStay
    }

    func show() {
        let host = NSHostingView(rootView: MoveView(state: state, move: { [weak self] in self?.move() },
                                                    notNow: { [weak self] in self?.window?.close() }))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = Design.Copy.Move.windowTitle
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = host
        // Paper is always light, Terminal always dark, Mono follows the system: as the other windows do.
        let theme = Design.theme
        window.appearance = theme.isAlwaysDark ? NSAppearance(named: .darkAqua) : (theme.isAlwaysLight ? NSAppearance(named: .aqua) : nil)
        window.backgroundColor = .tone(Design.Colors.paper)
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func move() {
        switch MoveToApplications.move(bundlePath: bundlePath, home: home, mover: mover) {
        case .relaunching: break
        case let .failed(reason): state.problem = reason
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard !stayed else { return }
        stayed = true
        onStay()
    }
}

@MainActor
@Observable
final class MoveState {
    var problem: String?
}

struct MoveView: View {
    let state: MoveState
    let move: () -> Void
    let notNow: () -> Void

    private typealias C = Design.Copy.Move

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.l) {
            Text(C.heading)
                .font(.text(Design.TypeScale.h2, weight: .semibold))
                .foregroundStyle(Color.ink)
            Text(C.explain)
                .font(.proseSmall)
                .foregroundStyle(Color.mute)
                .lineSpacing(Design.TypeScale.codeLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = state.problem {
                Text(problem)
                    .font(.proseSmall)
                    .foregroundStyle(Color.problem)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text(C.notNowNote)
                .font(.proseSmall)
                .foregroundStyle(Color.mute)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Design.Space.m) {
                Spacer()
                Button(action: notNow) {
                    Text(C.notNow)
                        .font(.text(Design.TypeScale.small, weight: .medium))
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, Design.Space.l)
                        .frame(height: Design.Bubble.buttonHeight)
                        .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).strokeBorder(Color.line, lineWidth: Design.Bubble.hairline))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .keyboardShortcut(.cancelAction)
                Button(action: move) {
                    Text(C.move)
                        .font(.text(Design.TypeScale.small, weight: .medium))
                        .foregroundStyle(Color.paper)
                        .padding(.horizontal, Design.Space.l)
                        .frame(height: Design.Bubble.buttonHeight)
                        .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(Color.ink))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Setup.padding)
        .frame(width: Design.Move.width, alignment: .leading)
        .background(Color.paper)
        .tint(.signal)
    }
}
