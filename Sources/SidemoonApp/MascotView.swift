import AppKit
import SwiftUI
import SidemoonCompanion
import SidemoonCore

/// What the mascot is showing. Each state changes the mark's shape as well as its colour.
enum MascotState: Equatable {
    case idle, capturing, holding, sending, waiting, reply, error

    @MainActor
    init(_ model: CompanionModel) {
        switch model.status.activity {
        case .capturing: self = .capturing
        case .holding: self = .holding
        case .sending: self = .sending
        case .waiting: self = .waiting
        case .failed: self = .error
        case .idle:
            // A new answer comes first; otherwise the mark shows the session working, whoever asked.
            if model.status.unseenReply { self = .reply } else { self = model.target?.state == .working ? .waiting : .idle }
        }
    }

    var label: String {
        switch self {
        case .idle: return Design.Copy.stateReady
        case .capturing: return Design.Copy.stateCapturing
        case .holding: return Design.Copy.stateNote
        case .sending: return Design.Copy.stateSending
        case .waiting: return Design.Copy.stateWaiting
        case .reply: return Design.Copy.stateNewReply
        case .error: return Design.Copy.stateProblem
        }
    }

    /// Seconds per orbit while the satellite is travelling; nil when it rests.
    var orbitPeriod: TimeInterval? {
        switch self {
        case .sending: return Design.Mascot.sendingPeriod
        case .waiting: return Design.Mascot.waitingPeriod
        default: return nil
        }
    }
}

/// Real glass: blurs whatever is behind the window.
struct GlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The orbit, starting at twelve o'clock and running clockwise so a trim reads as a countdown.
struct OrbitShape: Shape {
    func path(in rect: CGRect) -> Path {
        let u = rect.width / Design.Mascot.grid
        let c = Design.Mascot.center
        var path = Path()
        path.addArc(center: CGPoint(x: rect.minX + c.x * u, y: rect.minY + c.y * u), radius: Design.Mascot.orbitRadius * u,
                    startAngle: .degrees(-90), endAngle: .degrees(270), clockwise: false)
        return path
    }
}

/// The collapsed companion in its panel.
/// Whether the pointer is over the mascot. The panel's AppKit view sets it: SwiftUI hover is not delivered
/// reliably to a panel that never becomes key.
@MainActor
@Observable
final class MascotHover {
    var isHovering = false
}

struct MascotView: View {
    let model: CompanionModel
    var hover: MascotHover?

    var body: some View {
        let state = MascotState(model)
        MascotFigure(state: state, countdown: model.noteCountdown, hovering: hover?.isHovering ?? false,
                     attention: model.attentionRequests)
            // The badge sits on the lens's own corner; the panel around it is only clear room.
            .overlay(alignment: .topTrailing) {
                if model.waitingCount > 0, !model.isExpanded { MascotBadge(count: model.waitingCount) }
            }
            .frame(width: CompanionConstants.Layout.mascotSize, height: CompanionConstants.Layout.mascotSize)
            .help("Sidemoon: \(state.label)")
            // A new size redraws the mark from the size tokens.
            .id("\(model.zoom)-\(model.theme.rawValue)")
    }
}

/// The mascot itself: a glass lens with a centre point and a small dot on a hairline orbit.
struct MascotFigure: View {
    let state: MascotState
    let countdown: NoteCountdown?
    var hovering = false
    /// Goes up when the mascot should pulse a few times so the eye finds it.
    var attention = 0
    var side: CGFloat = Design.Mascot.drawnSize
    /// Lit as under the pointer, for one beat of an attention pulse.
    @State private var glowing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = 0
    /// Extra degrees the resting dot has travelled: one lap per hover.
    @State private var hoverLap: Double = 0
    /// Where the shine is across the disc: -1 off the left edge, 1 off the right.
    @State private var shine: CGFloat = -1

    var body: some View {
        let m = Design.Mascot.self
        let u = side / m.grid
        let disc = m.discRadius * 2 * u

        ZStack {
            Circle()
                .fill(Color(Design.Colors.mascotBody))
                .background(GlassBackdrop().clipShape(Circle()))
                .overlay(Circle().fill(RadialGradient(colors: [accent.opacity(m.tintOpacity), accent.opacity(m.tintOpacity / 4)],
                                                      center: .bottomTrailing, startRadius: 0, endRadius: disc)))
                .overlay(shineBand(disc: disc).clipShape(Circle()))
                .overlay(Circle().strokeBorder(lit ? accent : Color(Design.Colors.mascotEdge), lineWidth: m.edgeStroke))
                .frame(width: disc, height: disc)
                .shadow(color: Color(Design.Colors.mascotShadow), radius: m.shadowRadius, y: m.shadowOffsetY)
                .shadow(color: accent.opacity(lit ? m.hoverGlowOpacity : 0), radius: m.hoverGlowRadius)
            orbit(u: u)
                .keyframeAnimator(initialValue: CGFloat(1), trigger: pulse) { content, scale in
                    content.scaleEffect(scale)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(m.replyPulseScale, duration: Design.Motion.base / 2)
                        CubicKeyframe(1, duration: Design.Motion.base / 2)
                    }
                }
            core(u: u)
            satellite(u: u)
        }
        .frame(width: side, height: side)
        .scaleEffect(lit && !reduceMotion ? m.hoverScale : 1)
        .animation(.spring(duration: Design.Motion.base, bounce: 0.35), value: lit)
        .onChange(of: attention) { pulseForAttention() }
        .onChange(of: state) { old, new in
            if new == .reply, old != .reply, !reduceMotion { pulse += 1 }
        }
        .onChange(of: hovering) { _, now in
            guard now, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: m.hoverLapDuration)) { hoverLap += 360 }
            shine = -1
            withAnimation(.easeOut(duration: m.shineDuration)) { shine = 1 }
        }
    }

    private var lit: Bool { hovering || glowing }

    /// Lights the lens and lets it go a few times in a row.
    private func pulseForAttention() {
        let m = Design.Mascot.self
        Task { @MainActor in
            for _ in 0..<m.attentionPulses {
                withAnimation(.easeOut(duration: m.attentionPulseDuration)) { glowing = true }
                try? await Task.sleep(for: .seconds(m.attentionPulseDuration))
                withAnimation(.easeIn(duration: m.attentionPulseDuration)) { glowing = false }
                try? await Task.sleep(for: .seconds(m.attentionPulseDuration))
            }
        }
    }

    /// A soft band of light that crosses the lens once when the pointer arrives.
    private func shineBand(disc: CGFloat) -> some View {
        let m = Design.Mascot.self
        return LinearGradient(colors: [.clear, .white.opacity(m.shineOpacity), .clear], startPoint: .leading, endPoint: .trailing)
            .frame(width: disc * m.shineWidth, height: disc * 2)
            .rotationEffect(.degrees(m.shineTilt))
            .offset(x: shine * disc)
            .allowsHitTesting(false)
    }

    private var mark: Color { Color(Design.Colors.mascotMark) }
    private var accent: Color { Color(Design.Colors.mascotAccent) }

    @ViewBuilder
    private func orbit(u: CGFloat) -> some View {
        let m = Design.Mascot.self
        switch state {
        case .capturing:
            // Four viewfinder brackets, centred on the diagonals.
            let quarter = 2 * .pi * m.orbitRadius * u / 4
            OrbitShape().stroke(mark, style: StrokeStyle(
                lineWidth: m.orbitStrokeActive, lineCap: .butt, dash: [m.bracketDash * quarter, m.bracketGap * quarter],
                dashPhase: (1 - m.bracketGap / 2) * quarter))
        case .holding:
            if let countdown {
                OrbitShape().stroke(mark.opacity(m.orbitTrackOpacity), lineWidth: m.orbitStroke)
                OrbitShape()
                    .trim(from: 0, to: countdown.fractionRemaining)
                    .stroke(accent, style: StrokeStyle(lineWidth: m.orbitStrokeActive, lineCap: .round))
                    .animation(.linear(duration: countdown.tickInterval), value: countdown.fractionRemaining)
            } else {
                OrbitShape().stroke(mark, lineWidth: m.orbitStroke)
            }
        case .error:
            OrbitShape().stroke(mark.opacity(m.orbitTrackOpacity * 2), lineWidth: m.orbitStroke)
        default:
            // The ring carries the accent, so the mark has colour at rest.
            OrbitShape().stroke(accent, lineWidth: m.orbitStrokeResting)
        }
    }

    /// The centre point. It shrinks while capturing and flattens to a bar on a problem.
    private func core(u: CGFloat) -> some View {
        let m = Design.Mascot.self
        let size: CGSize
        var color = mark
        switch state {
        case .capturing: size = CGSize(width: m.coreRadiusCapturing * 2, height: m.coreRadiusCapturing * 2)
        case .error:
            size = m.coreProblem
            color = Color(Design.Colors.mascotProblem)
        default: size = CGSize(width: m.coreRadius * 2, height: m.coreRadius * 2)
        }
        return Capsule()
            .fill(color)
            .frame(width: size.width * u, height: size.height * u)
            .animation(.easeOutCurve(Design.Motion.fast), value: state)
    }

    /// The companion dot. It rests at the upper right, travels the orbit while sending and waiting,
    /// turns to the accent when a reply lands, and steps aside while the orbit is a viewfinder or a countdown.
    @ViewBuilder
    private func satellite(u: CGFloat) -> some View {
        let m = Design.Mascot.self
        let hidden = state == .capturing || state == .holding || state == .error
        let radius = (state == .reply ? m.satelliteRadiusReply : m.satelliteRadius) * u
        let dot = Circle()
            // The dot is the one spot of colour, at rest too.
            .fill(accent)
            .frame(width: radius * 2, height: radius * 2)
            .offset(x: m.orbitRadius * u)
            .opacity(hidden ? 0 : 1)

        if let period = state.orbitPeriod, !reduceMotion {
            TimelineView(.animation) { context in
                let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                dot.rotationEffect(.degrees(m.restAngle + 360 * turn))
            }
        } else if state.orbitPeriod != nil {
            // Reduce Motion: the dot stays put and breathes instead of travelling.
            TimelineView(.animation) { context in
                let wave = (sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / Design.Mascot.waitingPeriod) + 1) / 2
                dot.rotationEffect(.degrees(m.restAngle))
                    .opacity(m.reducedMotionWaitingOpacity + (1 - m.reducedMotionWaitingOpacity) * wave)
            }
        } else {
            dot.rotationEffect(.degrees(m.restAngle + hoverLap))
                .animation(.easeOutCurve(Design.Motion.fast), value: state)
        }
    }
}

/// A small counter on the mascot's corner: sessions with an answer to read or a prompt to answer.
/// It breathes gently so it is noticed without shouting.
struct MascotBadge: View {
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swollen = false

    var body: some View {
        let m = Design.Mascot.self
        Text(count > m.badgeMaxCount ? "\(m.badgeMaxCount)+" : "\(count)")
            .font(.system(size: m.badgeText, weight: .bold, design: .rounded))
            .foregroundStyle(Color.paper)
            .frame(minWidth: m.badgeSize, minHeight: m.badgeSize)
            .background(Capsule().fill(Color.signal))
            .overlay(Capsule().strokeBorder(Color.paper, lineWidth: m.badgeRing))
            .scaleEffect(swollen ? m.badgePulseScale : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: m.badgePulseDuration).repeatForever(autoreverses: true)) { swollen = true }
            }
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel(Design.Copy.waitingBadge(count))
    }
}
