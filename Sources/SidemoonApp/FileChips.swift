import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SidemoonCompanion

/// What kind of file a chip stands for, and what a click on it does.
enum MentionedFile {
    case media, image, document, other

    init(_ url: URL) {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .audiovisualContent) || type.conforms(to: .audio) {
            self = .media
        } else if type.conforms(to: .image) {
            self = .image
        } else if type.conforms(to: .pdf) || (type.conforms(to: .text) && !type.conforms(to: .script) && !type.conforms(to: .executable)) {
            self = .document
        } else {
            self = .other
        }
    }

    var symbol: String {
        switch self {
        case .media: return "play.fill"
        case .image: return "photo"
        case .document: return "doc.text"
        case .other: return "folder"
        }
    }

    /// Media, pictures and documents open in their default app. Anything else (scripts, apps, archives,
    /// unknown types) is only shown in Finder: opening those could run them.
    @MainActor
    static func open(_ url: URL) {
        switch MentionedFile(url) {
        case .media, .image, .document: NSWorkspace.shared.open(url)
        case .other: NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// The local files an answer mentions, each one click away.
struct FileChips: View {
    let files: [URL]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Design.Space.s) {
                ForEach(files, id: \.self) { FileChip(url: $0) }
            }
        }
    }
}

struct FileChip: View {
    let url: URL
    @State private var hovering = false

    var body: some View {
        let kind = MentionedFile(url)
        Button { MentionedFile.open(url) } label: {
            HStack(spacing: Design.Space.xs) {
                Image(systemName: kind.symbol)
                    .font(.system(size: Design.Bubble.chipIcon, weight: .semibold))
                    .foregroundStyle(Color.signal)
                Text(url.lastPathComponent)
                    .font(.proseSmall)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, Design.Space.m)
            .frame(height: Design.Bubble.pillHeight)
            .frame(maxWidth: Design.Bubble.chipMaxWidth, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(hovering ? Color.sent : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).strokeBorder(Color.signalSoft, lineWidth: Design.Bubble.hairline))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help(kind == .other ? Design.Copy.showInFinder(url.path) : Design.Copy.openFile(url.path))
        .contextMenu {
            Button(Design.Copy.showInFinderTitle) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}
