import AppKit
import SwiftUI
import SidemoonCompanion

extension NSColor {
    convenience init(_ hex: Design.Hex) {
        self.init(srgbRed: hex.red, green: hex.green, blue: hex.blue, alpha: hex.alpha)
    }

    /// Resolves a tone for the current appearance, honouring Increase Contrast.
    static func tone(_ tone: Design.Tone) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua,
                                                   .accessibilityHighContrastVibrantDark, .aqua]) != .aqua
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            if dark { return NSColor(contrast ? tone.darkContrast ?? tone.dark : tone.dark) }
            return NSColor(contrast ? tone.lightContrast ?? tone.light : tone.light)
        }
    }
}

extension Color {
    init(_ tone: Design.Tone) { self.init(nsColor: .tone(tone)) }

    static var paper: Color { Color(Design.Colors.paper) }
    static var paper2: Color { Color(Design.Colors.paper2) }
    static var ink: Color { Color(Design.Colors.ink) }
    static var mute: Color { Color(Design.Colors.mute) }
    static var line: Color { Color(Design.Colors.line) }
    static var surface: Color { Color(Design.Colors.surface) }
    static var signal: Color { Color(Design.Colors.signal) }
    static var signalSoft: Color { Color(Design.Colors.signalSoft) }
    static var sent: Color { Color(Design.Colors.sent) }
    static var problem: Color { Color(Design.Colors.error) }
}

extension Font {
    /// The readout voice: small uppercase mono, used for state, counts and keys.
    // Qualified because `Design` alone means `Font.Design` inside this extension.
    // Computed, so they follow the user's size setting.
    static var readout: Font { .system(size: SidemoonCompanion.Design.TypeScale.label, design: .monospaced) }
    static var prose: Font { .text(SidemoonCompanion.Design.TypeScale.body) }
    static var proseSmall: Font { .text(SidemoonCompanion.Design.TypeScale.small) }
    /// Content text at a size and weight, in the theme's face (monospaced for Terminal).
    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: SidemoonCompanion.Design.theme.isMonospaced ? .monospaced : .default)
    }
    static var code: Font { .system(size: SidemoonCompanion.Design.TypeScale.code, design: .monospaced) }
}

extension Animation {
    static func easeOutCurve(_ duration: TimeInterval) -> Animation {
        let c = Design.Motion.easeOut
        return .timingCurve(c.0, c.1, c.2, c.3, duration: duration)
    }
}

/// Small uppercase mono label.
struct ReadoutText: View {
    let text: String
    var color: Color = .mute

    init(_ text: String, color: Color = .mute) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.readout)
            .tracking(Design.TypeScale.labelTracking)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// Buttons shrink slightly while pressed.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? Design.Motion.pressScale : 1)
            .animation(.easeOutCurve(Design.Motion.press), value: configuration.isPressed)
    }
}
