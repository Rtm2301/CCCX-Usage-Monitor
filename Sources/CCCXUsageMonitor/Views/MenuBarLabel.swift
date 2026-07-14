import SwiftUI
import AppKit

/// Compact menu bar label. Bars mode: one bar per *configured* service,
/// outlined in its identity color (Claude = orange, Codex = white — same as
/// the app icon's rings); unconfigured services are hidden.
struct MenuBarIconLabel: View {
    let state: AppState
    @AppStorage("menuBarStyle") private var style = "bars"

    private var bars: [MenuBarIcon.Bar] {
        var result: [MenuBarIcon.Bar] = []
        if state.claudeConfigured {
            result.append(MenuBarIcon.Bar(
                pct: state.displayPercent(service: "claude"),
                problem: state.claudeShowWarning,
                outline: .systemOrange))
        }
        if state.codexConfigured {
            result.append(MenuBarIcon.Bar(
                pct: state.displayPercent(service: "codex"),
                problem: state.codexStatus.isProblem && !state.codexIsFallback,
                outline: .white))
        }
        return result
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

    /// Text mode: identity-colored dot + percentage per service
    /// ("● 74%  ○ 32%" — orange dot = Claude, white dot = Codex).
    /// Image height = menu bar thickness so vertical centering is exact.
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
            // Center digits' cap height on the midline; dots share that center.
            let capCenter = height / 2
            var x: CGFloat = 0
            for (i, entry) in entries.enumerated() {
                let dotRect = NSRect(x: x, y: capCenter - dotSize / 2, width: dotSize, height: dotSize)
                entry.color.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
                // Contrasting ring: white around orange, black around white.
                let ringColor: NSColor = entry.color == .systemOrange
                    ? .white.withAlphaComponent(0.9)
                    : .black.withAlphaComponent(0.65)
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

    static func render(bars: [Bar]) -> NSImage {
        let width: CGFloat = 24
        let height: CGFloat = NSStatusBar.system.thickness
        let barWidth: CGFloat = 22
        let barHeight: CGFloat = 5.5

        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            func drawBar(_ bar: Bar, y: CGFloat) {
                let outlineRect = NSRect(x: 1, y: y, width: barWidth, height: barHeight)
                let radius = barHeight / 2

                // Track.
                NSColor.gray.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: outlineRect, xRadius: radius, yRadius: radius).fill()

                // Fill (severity color), inset so the outline stays visible.
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

                // Identity outline (orange = Claude, white = Codex).
                bar.outline.withAlphaComponent(0.9).setStroke()
                let outline = NSBezierPath(roundedRect: outlineRect.insetBy(dx: 0.5, dy: 0.5),
                                           xRadius: radius, yRadius: radius)
                outline.lineWidth = 1
                outline.stroke()
            }

            if bars.count == 1 {
                drawBar(bars[0], y: (height - barHeight) / 2)
            } else {
                let gap: CGFloat = 2
                let bottom = (height - (barHeight * 2 + gap)) / 2
                for (i, bar) in bars.enumerated() {
                    drawBar(bar, y: i == 0 ? bottom + barHeight + gap : bottom)
                }
            }
            return true
        }
    }
}
