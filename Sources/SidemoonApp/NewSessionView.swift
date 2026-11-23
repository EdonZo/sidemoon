import AppKit
import SwiftUI
import SidemoonCompanion
import SidemoonCore

/// A button in the companion's cards and forms: filled with ink for the main step, outlined for the others.
struct FormButton: View {
    let title: String
    let primary: Bool
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.text(Design.TypeScale.small, weight: .medium))
                .foregroundStyle(primary ? (enabled ? Color.paper : Color.mute) : Color.ink)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Design.Space.l)
                .frame(height: Design.Bubble.buttonHeight)
                .background(RoundedRectangle(cornerRadius: Design.Radius.control)
                    .fill(primary ? (enabled ? Color.ink : Color.paper2) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.control)
                    .strokeBorder(primary ? Color.clear : Color.line, lineWidth: Design.Bubble.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
    }
}

/// Starting a new background session: which folder, and the first message. While it starts the form says so and
/// cannot be left; if it fails it says why in plain words, with what Claude Code printed behind Details.
struct NewSessionView: View {
    @Bindable var model: CompanionModel
    @FocusState private var messageFocused: Bool
    @State private var showsDetail = false

    private var copy: Design.Copy.NewSession.Type { Design.Copy.NewSession.self }

    var body: some View {
        let form = model.newSession
        let starting = form.isStarting
        VStack(alignment: .leading, spacing: Design.Space.xl) {
            HStack(spacing: Design.Space.m) {
                ReadoutText(copy.heading, color: .signal)
                Spacer(minLength: 0)
                if !starting {
                    Button { model.closeNewSession() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: Design.Bubble.chipIcon, weight: .semibold))
                            .foregroundStyle(Color.mute)
                            .frame(width: Design.Bubble.pillHeight, height: Design.Bubble.pillHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .help(Design.Copy.cancel)
                }
            }
            folders(form)
            VStack(alignment: .leading, spacing: Design.Space.s) {
                ReadoutText(copy.message)
                TextField(copy.messagePlaceholder, text: $model.newSessionMessage)
                    .textFieldStyle(.plain)
                    .font(.prose)
                    .foregroundStyle(Color.ink)
                    .focused($messageFocused)
                    .onSubmit(start)
                    .onExitCommand { model.closeNewSession() }
                    .disabled(starting)
                    .padding(.horizontal, Design.Space.m)
                    .frame(minHeight: Design.Bubble.buttonHeight)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(messageFocused ? Color.sent : Color.paper2))
                    .overlay(RoundedRectangle(cornerRadius: Design.Radius.control)
                        .strokeBorder(messageFocused && model.hasKeyboard ? Color.signal : Color.clear, lineWidth: Design.Bubble.focusRing))
            }
            if let problem = form.problem { problemCard(problem, detail: form.problemDetail) }
            if starting {
                VStack(alignment: .leading, spacing: Design.Space.s) {
                    HStack(spacing: Design.Space.m) {
                        ReadoutText(copy.starting, color: .signal)
                        WorkingDots()
                        Spacer(minLength: 0)
                    }
                    Text(copy.startingNote)
                        .font(.proseSmall)
                        .foregroundStyle(Color.mute)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Design.Space.m) { buttons }
                    VStack(alignment: .leading, spacing: Design.Space.s) { buttons }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { messageFocused = true }
        .onChange(of: form.problem) { showsDetail = false }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: Design.Space.m) {
            FormButton(title: model.newSession.problem == nil ? copy.start : copy.tryAgain, primary: true,
                       enabled: model.canStartNewSession, action: start)
            FormButton(title: Design.Copy.cancel, primary: false) { model.closeNewSession() }
        }
        ReadoutText(copy.returnStarts)
    }

    private func start() {
        guard model.canStartNewSession else { return }
        Task { await model.startNewSession() }
    }

    // MARK: Folder

    @ViewBuilder
    private func folders(_ form: NewSessionForm) -> some View {
        let recent = model.recentFolders
        // A folder chosen with the panel is listed too, under the recent ones.
        let shown = recent + [form.folder].compactMap { $0 }.filter { !recent.contains($0) }
        VStack(alignment: .leading, spacing: Design.Space.s) {
            ReadoutText(copy.folder)
            if shown.isEmpty {
                Text(copy.noFolderYet)
                    .font(.proseSmall)
                    .foregroundStyle(Color.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: Design.Space.xxs) {
                ForEach(shown, id: \.self) { folder in
                    FolderRow(path: folder, home: model.homeFolder, selected: folder == form.folder) {
                        model.chooseNewSessionFolder(folder)
                    }
                    .disabled(form.isStarting)
                }
            }
            if model.folderChooser != nil {
                Button { Task { await model.pickNewSessionFolder() } } label: {
                    HStack(spacing: Design.Space.xs) {
                        Image(systemName: "folder")
                            .font(.system(size: Design.Bubble.rowActionIcon, weight: .medium))
                        ReadoutText(copy.chooseFolder, color: .ink)
                    }
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, Design.Space.m)
                    .frame(height: Design.Bubble.pillHeight)
                    .overlay(RoundedRectangle(cornerRadius: Design.Radius.control)
                        .strokeBorder(Color.line, lineWidth: Design.Bubble.hairline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help(copy.chooseFolderHelp)
                .disabled(form.isStarting)
            }
            if let note = model.newSessionFolderNote {
                Text(noteText(note))
                    .font(.proseSmall)
                    .foregroundStyle(note.blocksStart ? Color.problem : Color.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func noteText(_ note: FolderNote) -> String {
        switch note {
        case .homeCaution: return copy.homeCaution
        case .homeRefused: return copy.homeRefused
        case .missing: return copy.folderMissing
        }
    }

    // MARK: Problem

    private func problemCard(_ problem: NewSessionProblem, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.m) {
                Circle().fill(Color.problem)
                    .frame(width: Design.Bubble.errorDot, height: Design.Bubble.errorDot)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + Design.Space.xxs }
                VStack(alignment: .leading, spacing: Design.Space.xxs) {
                    Text(problem.title)
                        .font(.text(Design.TypeScale.body, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(problem.advice)
                        .font(.proseSmall)
                        .foregroundStyle(Color.mute)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if let detail, !detail.isEmpty {
                let words = Design.Copy.Unreachable.self
                Button { showsDetail.toggle() } label: {
                    HStack(spacing: Design.Space.xs) {
                        Image(systemName: showsDetail ? "chevron.down" : "chevron.right")
                            .font(.system(size: Design.Bubble.chipIcon, weight: .semibold))
                            .foregroundStyle(Color.mute)
                        ReadoutText(showsDetail ? words.hideDetails : words.details)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                if showsDetail {
                    Text(detail)
                        .font(.system(size: Design.TypeScale.code, design: .monospaced))
                        .foregroundStyle(Color.mute)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(Design.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(Color.paper2))
                }
            }
        }
        .padding(Design.Bubble.entryPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
            .strokeBorder(Color.line, lineWidth: Design.Bubble.hairline))
    }
}

/// One folder to start in: its name, and where it is.
struct FolderRow: View {
    let path: String
    let home: String
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: Design.Space.m) {
                Circle()
                    .fill(selected ? Color.signal : Color.clear)
                    .overlay(Circle().strokeBorder(selected ? Color.clear : Color.line, lineWidth: Design.Bubble.hairline))
                    .frame(width: Design.Bubble.errorDot, height: Design.Bubble.errorDot)
                Text(name)
                    .font(.text(Design.TypeScale.body, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(parent)
                    .font(.proseSmall)
                    .foregroundStyle(Color.mute)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .fill(hovering ? Color.paper2 : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
    }

    /// The home folder is named as such, and the folders in it are written from "~".
    private var name: String {
        ResumeCheck.isHomeFolder(path, home: home) ? Design.Copy.NewSession.homeFolderName : (path as NSString).lastPathComponent
    }

    private var parent: String {
        guard !ResumeCheck.isHomeFolder(path, home: home) else { return "" }
        let up = (path as NSString).deletingLastPathComponent
        if up == home { return "~" }
        return up.hasPrefix(home + "/") ? "~" + up.dropFirst(home.count) : up
    }
}

/// The three dots that brighten in turn while something is under way.
struct WorkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: Design.Bubble.workingDotGap) {
                    ForEach(0..<Design.Bubble.workingDots, id: \.self) { index in
                        let phase = (t / Design.Motion.workingCycle - Double(index) / Double(Design.Bubble.workingDots))
                        let wave = (sin(phase * 2 * .pi) + 1) / 2
                        Circle()
                            .fill(Color.signal)
                            .frame(width: Design.Bubble.workingDot, height: Design.Bubble.workingDot)
                            .opacity(Design.Bubble.workingDotMinOpacity + (1 - Design.Bubble.workingDotMinOpacity) * wave)
                    }
                }
            }
        }
    }
}

/// The system's folder panel, for "Choose folder…".
@MainActor
final class FolderPanel: FolderChooser {
    func chooseFolder(startingAt: String?) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = Design.Copy.NewSession.panelMessage
        panel.prompt = Design.Copy.NewSession.panelPrompt
        // With nothing chosen before, it opens in the home folder: the natural place to make a new project folder.
        panel.directoryURL = URL(fileURLWithPath: startingAt ?? NSHomeDirectory(), isDirectory: true)
        // Sidemoon is never active while the user works elsewhere; the panel needs it to be, to take the keyboard.
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        return url.standardizedFileURL.path
    }
}
