import AppKit
import SwiftUI

/// Transparent AppKit layer over the waveform canvas: SwiftUI has no access
/// to trackpad scroll deltas or pinch anchors, so pan/zoom events are caught
/// here and forwarded as deltas. Vertical scrolls fall through to the
/// enclosing ScrollView.
struct WaveformInteractionView: NSViewRepresentable {
    /// Positive delta shifts the viewport later in time (in view points).
    var onPan: (Double) -> Void
    /// factor > 1 zooms out; anchorX is in view points from the left edge.
    var onZoom: (_ factor: Double, _ anchorX: Double) -> Void
    /// A click (press + release with < 3 pt of travel); x in view points.
    var onSeek: (_ anchorX: Double) -> Void

    func makeNSView(context: Context) -> InteractionNSView {
        let view = InteractionNSView()
        view.onPan = onPan
        view.onZoom = onZoom
        view.onSeek = onSeek
        return view
    }

    func updateNSView(_ view: InteractionNSView, context: Context) {
        view.onPan = onPan
        view.onZoom = onZoom
        view.onSeek = onSeek
    }

    final class InteractionNSView: NSView {
        var onPan: ((Double) -> Void)?
        var onZoom: ((Double, Double) -> Void)?
        var onSeek: ((Double) -> Void)?
        private var lastDragX: CGFloat?
        private var totalDragDistance: CGFloat = 0
        private var pressActive = false

        private func localX(_ event: NSEvent) -> Double {
            Double(convert(event.locationInWindow, from: nil).x)
        }

        override func scrollWheel(with event: NSEvent) {
            if event.modifierFlags.contains(.option) {
                // Fingers up = zoom in (natural scrolling reports that as
                // a negative deltaY... times the invert flag; exp keeps the
                // factor positive and symmetric either way).
                let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
                onZoom?(exp(Double(delta) * 0.015), localX(event))
            } else if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                onPan?(Double(-event.scrollingDeltaX))
            } else {
                super.scrollWheel(with: event)
            }
        }

        override func magnify(with event: NSEvent) {
            let factor = 1 / (1 + Double(event.magnification))
            guard factor.isFinite, factor > 0 else { return }
            onZoom?(factor, localX(event))
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onZoom?(event.modifierFlags.contains(.option) ? 2 : 0.5, localX(event))
                lastDragX = nil
                pressActive = false
            } else {
                lastDragX = convert(event.locationInWindow, from: nil).x
                totalDragDistance = 0
                pressActive = true
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let last = lastDragX else { return }
            let x = convert(event.locationInWindow, from: nil).x
            totalDragDistance += abs(last - x)
            onPan?(Double(last - x))
            lastDragX = x
        }

        override func mouseUp(with event: NSEvent) {
            if pressActive, totalDragDistance < 3 {
                onSeek?(localX(event))
            }
            pressActive = false
            lastDragX = nil
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}
