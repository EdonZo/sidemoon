import AppKit
import SwiftUI
import SidemoonCompanion

/// The corner handle that resizes the bubble. It sits on the corner away from the mascot, since that is
/// the corner that moves: the bubble stays attached to the mascot and grows the other way.
struct ResizeGrip: View {
    let model: CompanionModel
    /// Where the pointer and the bubble were when the drag began. The pointer is read from the screen,
    /// not from the gesture: the view moves under the pointer as the window changes size.
    @State private var start: (pointer: CGPoint, size: CGSize)?
    @State private var hovering = false

    var body: some View {
        let side = Design.Bubble.gripSize
        Canvas { context, size in
            // Three short diagonal strokes, pointing into the corner being dragged.
            var path = Path()
            for step in 1...3 {
                let inset = CGFloat(step) * size.width / 4
                path.move(to: CGPoint(x: size.width - inset, y: size.height))
                path.addLine(to: CGPoint(x: size.width, y: size.height - inset))
            }
            context.stroke(path, with: .color(hovering || start != nil ? Color.signal : Color.mute.opacity(0.7)),
                           style: StrokeStyle(lineWidth: Design.Bubble.hairline * 1.4, lineCap: .round))
        }
        .frame(width: side, height: side)
        // Drawn for the bottom-right corner, then turned to face whichever corner it is on.
        .scaleEffect(x: model.bubbleGrowsLeft ? -1 : 1, y: model.bubbleGrowsUp ? -1 : 1)
        .padding(Design.Space.xs)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { _ in
                    let pointer = NSEvent.mouseLocation
                    let began = start ?? (pointer, model.shownBubbleSize)
                    if start == nil { start = began }
                    // Screen coordinates run upwards; the bubble grows away from the mascot.
                    let dx = pointer.x - began.pointer.x, dy = pointer.y - began.pointer.y
                    model.resizeBubble(to: CGSize(width: began.size.width + (model.bubbleGrowsLeft ? -dx : dx),
                                                  height: began.size.height + (model.bubbleGrowsUp ? dy : -dy)))
                }
                .onEnded { _ in start = nil }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.resetBubbleSize() })
        .help(Design.Copy.resizeHelp)
    }
}
