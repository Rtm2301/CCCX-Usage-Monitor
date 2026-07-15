import SwiftUI
import AppKit

/// Compact menu bar label. Bars mode: one bar per visible service, outlined
/// in its identity color; text mode: identity dot + percentage per service.
struct MenuBarIconLabel: View {
    let state: AppState
    @AppStorage("menuBarStyle") private var style = "bars"

    private var bars: [MenuBarIcon.Bar] {
        state.visibleServices.map { s in
            MenuBarIcon.Bar(
                pct: state.displayPercent(service: s.rawValue),
                problem: state.showWarning(s),
                outline: s.menuOutline)
        }
    }

    var body: some View {
        if bars.isEmpty {
            Image(systemName: "gauge.with.needle")
        } else if style == "text" {
            Image(nsImage: MenuBarIcon.renderText(bars: bars))
                .accessibilityLabel(state.menuBarTitle)
        } else {
            Image(nsImage: MenuBarIcon.render(bars: bars))
                .accessibilityLabel(state.menuBarTitle)
        }
    }
}

enum MenuBarIcon {
    struct Bar {
        let pct: Double?
        let problem: Bool
        let outline: NSColor
    }

    /// Text mode: identity-colored dot + percentage per service.
    static func renderText(bars: [Bar]) -> NSImage {
        let height: CGFloat = NSStatusBar.system.thickness
        let dotSize: CGFloat = 7
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        let entries: [(color: NSColor, text: String)] = bars.map { bar in
            let text = bar.pct.map { "\(Int($0))%" } ?? "—"
            return (bar.outline, text + (bar.problem ? "⚠" : ""))
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        let dotGap: CGFloat = 3, groupGap: CGFloat = 8
        let textWidths = entries.map { ($0.text as NSString).size(withAttributes: attrs).width }
        let width = entries.indices.reduce(CGFloat(0)) { acc, i in
            acc + dotSize + dotGap + textWidths[i] + (i < entries.count - 1 ? groupGap : 0)
        }

        return NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            let capCenter = height / 2
            var x: CGFloat = 0
            for (i, entry) in entries.enumerated() {
                let dotRect = NSRect(x: x, y: capCenter - dotSize / 2, width: dotSize, height: dotSize)
                entry.color.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
                // Contrasting ring: black around light dots, white around colored ones.
                let ringColor: NSColor = entry.color == .white
                    ? .black.withAlphaComponent(0.65)
                    : .white.withAlphaComponent(0.9)
                ringColor.setStroke()
                let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.4, dy: 0.4))
                ring.lineWidth = 0.8
                ring.stroke()
                x += dotSize + dotGap

                let baseline = capCenter - font.capHeight / 2
                (entry.text as NSString).draw(
                    at: NSPoint(x: x, y: baseline + font.descender),
                    withAttributes: attrs)
                x += textWidths[i] + groupGap
            }
            return true
        }
    }

    /// Bars mode: stacked mini-bars (fits up to 4 within the menu bar height).
    static func render(bars: [Bar]) -> NSImage {
        let width: CGFloat = 24
        let height: CGFloat = NSStatusBar.system.thickness
        let barWidth: CGFloat = 22
        let n = CGFloat(max(bars.count, 1))
        let gap: CGFloat = n > 2 ? 1.5 : 2
        let barHeight: CGFloat = min(5.5, (height - 2 - gap * (n - 1)) / n)

        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            func drawBar(_ bar: Bar, y: CGFloat) {
                let outlineRect = NSRect(x: 1, y: y, width: barWidth, height: barHeight)
                let radius = barHeight / 2

                NSColor.gray.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: outlineRect, xRadius: radius, yRadius: radius).fill()

                let inset: CGFloat = 1.3
                if let pct = bar.pct {
                    let innerWidth = barWidth - inset * 2
                    let fillWidth = max(barHeight - inset * 2, innerWidth * CGFloat(min(pct, 100)) / 100)
                    let color: NSColor = bar.problem ? .systemOrange
                        : pct < 60 ? .systemGreen
                        : pct < 85 ? .systemYellow
                        : .systemRed
                    color.setFill()
                    let innerRadius = (barHeight - inset * 2) / 2
                    NSBezierPath(roundedRect: NSRect(x: 1 + inset, y: y + inset,
                                                     width: fillWidth, height: barHeight - inset * 2),
                                 xRadius: innerRadius, yRadius: innerRadius).fill()
                } else if bar.problem {
                    NSColor.systemOrange.withAlphaComponent(0.4).setFill()
                    NSBezierPath(roundedRect: outlineRect.insetBy(dx: 1.3, dy: 1.3),
                                 xRadius: radius, yRadius: radius).fill()
                }

                bar.outline.withAlphaComponent(0.9).setStroke()
                let outline = NSBezierPath(roundedRect: outlineRect.insetBy(dx: 0.5, dy: 0.5),
                                           xRadius: radius, yRadius: radius)
                outline.lineWidth = 1
                outline.stroke()
            }

            let total = barHeight * n + gap * (n - 1)
            let bottom = (height - total) / 2
            for (i, bar) in bars.enumerated() {
                // Index 0 sits highest.
                let y = bottom + (barHeight + gap) * CGFloat(bars.count - 1 - i)
                drawBar(bar, y: y)
            }
            return true
        }
    }
}
